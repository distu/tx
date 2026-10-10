import Foundation

/// Chama a API Gemini (REST) para gerar artefatos de inteligência a partir de transcrições.
/// The caller provides the API key from the macOS Keychain.
public actor IntelligenceEngine {

    public init() {}

    // MARK: - Public API

    public func generate(
        mode: IntelligenceMode,
        session: Session,
        segments: [TranscriptSegment],
        apiKey: String,
        model: GeminiModel = .intelligenceDefault
    ) async throws -> IntelligenceArtifact {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntelligenceError.missingApiKey
        }
        guard !segments.isEmpty else {
            throw IntelligenceError.emptyTranscript
        }

        let prompt = try makePrompt(mode: mode, session: session, segments: segments)

        TxLogger.intelligence.info("Generating \(mode.rawValue, privacy: .public) for session \(session.id.uuidString, privacy: .public) (\(segments.count) segments) using \(model.rawValue, privacy: .public)")

        let content = try await callGemini(prompt: prompt, apiKey: apiKey, model: model)
        TxLogger.intelligence.info("Generated \(mode.rawValue, privacy: .public): \(content.count) chars")

        return IntelligenceArtifact(sessionId: session.id, mode: mode, content: content)
    }

    /// Prepara o mesmo pedido para qualquer provedor de inteligência textual.
    public func makePrompt(
        mode: IntelligenceMode,
        session: Session,
        segments: [TranscriptSegment]
    ) throws -> String {
        guard !segments.isEmpty else { throw IntelligenceError.emptyTranscript }
        return buildPrompt(mode: mode, transcript: formatTranscript(session: session, segments: segments))
    }

    // MARK: - Prompt building

    private func buildPrompt(mode: IntelligenceMode, transcript: String) -> String {
        let systemInstructions: String
        switch mode {
        case .ata:
            systemInstructions = """
Você é um analista de reuniões experiente. Sua tarefa é transformar a transcrição abaixo em uma \
**Ata de Reunião** estruturada e profissional.

Requisitos:
- NÃO omitir nenhuma informação relevante da transcrição
- Organizar por tópicos/assuntos discutidos (use cabeçalhos ## e ###)
- Preservar detalhes técnicos, números, nomes e contexto
- Corrigir apenas erros óbvios de transcrição (homofonias, palavras cortadas)
- Escrever em português formal com acentuação correta
- Identificar e destacar claramente: decisões tomadas, pendências e próximos passos
- Ao final, incluir uma seção ## Decisões e uma seção ## Próximos Passos

Formato de saída: Markdown
"""

        case .briefing:
            systemInstructions = """
Você é um analista executivo. Sua tarefa é criar um **Briefing** conciso e acionável \
a partir da transcrição abaixo.

Estrutura obrigatória (em Markdown):
## Resumo
(3 a 5 pontos-chave do que foi discutido)

## Contexto
(2 a 3 frases de contexto para quem não estava na reunião)

## Decisões Tomadas
(lista de decisões; "nenhuma" se não houver)

## Action Items
(tabela com | Ação | Responsável | Prazo |; preencha com "?" quando não mencionado)

## Observações
(pontos de atenção, riscos ou informações importantes que não se encaixam nas seções acima)

Seja direto, sem floreios. Escreva em português com acentuação correta.
"""
        }

        return """
\(systemInstructions)

---

TRANSCRIÇÃO:

\(transcript)
"""
    }

    private func formatTranscript(session: Session, segments: [TranscriptSegment]) -> String {
        var lines: [String] = []
        lines.append("Reunião: \(session.title)")
        lines.append("Data: \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
        if let duration = session.durationSeconds {
            lines.append("Duração: \(formatDuration(duration))")
        }
        lines.append("")

        for segment in segments {
            let speaker = segment.speaker == .you ? "Você" : "Outros"
            let ts = formatMs(segment.startMs)
            lines.append("[\(ts)] \(speaker): \(segment.text)")
        }

        return lines.joined(separator: "\n")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h\(m)min" }
        return "\(m)min\(s)s"
    }

    private func formatMs(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%02d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Gemini REST call

    private func callGemini(prompt: String, apiKey: String, model: GeminiModel) async throws -> String {
        guard let url = URL(string: GeminiModel.endpoint(for: model)) else {
            throw IntelligenceError.invalidConfiguration("URL inválida")
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.3,
                "maxOutputTokens": 8192,
                "responseMimeType": "text/plain"
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw IntelligenceError.networkError("Resposta inválida")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw IntelligenceError.apiError(http.statusCode, body)
        }

        return try parseGeminiResponse(data)
    }

    private func parseGeminiResponse(_ data: Data) throws -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else {
            let raw = String(data: data, encoding: .utf8) ?? "?"
            throw IntelligenceError.parseError("Resposta inesperada: \(raw.prefix(300))")
        }
        return text
    }
}

// MARK: - Errors

public enum IntelligenceError: LocalizedError {
    case missingApiKey
    case emptyTranscript
    case invalidConfiguration(String)
    case networkError(String)
    case apiError(Int, String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "Chave de API Gemini não configurada. Acesse Ajustes > Inteligência."
        case .emptyTranscript:
            return "A sessão não possui segmentos transcritos ainda."
        case .invalidConfiguration(let msg):
            return "Configuração inválida: \(msg)"
        case .networkError(let msg):
            return "Erro de rede: \(msg)"
        case .apiError(let code, let body):
            return "Erro da API Gemini (\(code)): \(body.prefix(200))"
        case .parseError(let msg):
            return "Erro ao interpretar resposta: \(msg)"
        }
    }
}
