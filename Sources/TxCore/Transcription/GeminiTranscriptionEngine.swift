import Foundation

/// Transcrição via Gemini API. Lê o arquivo de áudio em disco, codifica em
/// base64 e manda inline para `generateContent`. Aceita áudios curtos (ditado)
/// e meetings curtos (<18MB). Para arquivos maiores, deve-se usar a Files API
/// (a implementar em segunda iteração).
///
/// Vantagem sobre Whisper local: o LLM resolve siglas técnicas por contexto
/// ("EntraID" não vira "entradinho", "BFF" não vira "B F F").
public actor GeminiTranscriptionEngine {

    /// Limite seguro pra inline (Google aceita até 20MB, deixamos folga p/ JSON).
    public static let inlineSizeLimit: Int = 18 * 1024 * 1024

    public init() {}

    public func transcribe(
        audioPath: URL,
        apiKey: String,
        model: GeminiModel = .transcriptionDefault,
        language: String = "pt-BR",
        glossary: String = ""
    ) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiTranscriptionError.missingApiKey
        }
        let data = try Data(contentsOf: audioPath)
        guard data.count <= Self.inlineSizeLimit else {
            throw GeminiTranscriptionError.fileTooLarge(data.count)
        }
        let mime = mimeType(for: audioPath)
        let base64 = data.base64EncodedString()
        let prompt = buildPrompt(language: language, glossary: glossary)

        TxLogger.transcription.info("Gemini transcribe: file=\(audioPath.lastPathComponent, privacy: .public) bytes=\(data.count) model=\(model.rawValue, privacy: .public)")

        let text = try await callGemini(
            apiKey: apiKey,
            model: model,
            audioMime: mime,
            audioBase64: base64,
            prompt: prompt
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcrição segmentada com timestamps por turno de fala. Usa Structured
    /// Output do Gemini 2.5 (responseSchema) pra garantir um array JSON com
    /// `{startMs, endMs, text}`. Fundamental pra meetings — sem isso a UI
    /// agrupa tudo num bloco único e perde o fluxo da conversa.
    public func transcribeSegmented(
        audioPath: URL,
        apiKey: String,
        model: GeminiModel = .transcriptionDefault,
        language: String = "pt-BR",
        glossary: String = ""
    ) async throws -> [GeminiTranscribedSegment] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiTranscriptionError.missingApiKey
        }
        let data = try Data(contentsOf: audioPath)
        guard data.count <= Self.inlineSizeLimit else {
            throw GeminiTranscriptionError.fileTooLarge(data.count)
        }
        let mime = mimeType(for: audioPath)
        let base64 = data.base64EncodedString()
        let prompt = buildSegmentedPrompt(language: language, glossary: glossary)

        TxLogger.transcription.info("Gemini transcribeSegmented: file=\(audioPath.lastPathComponent, privacy: .public) bytes=\(data.count) model=\(model.rawValue, privacy: .public)")

        return try await callGeminiSegmented(
            apiKey: apiKey,
            model: model,
            audioMime: mime,
            audioBase64: base64,
            prompt: prompt
        )
    }

    /// Versão `[Float]` (samples 16k mono) — escreve um WAV temporário e usa o
    /// path-based. Conveniência pra reutilizar com o pipeline existente do
    /// `DictationCoordinator` que já tem `[Float]` no MainActor.
    public func transcribe(
        audioArray samples: [Float],
        sampleRate: Double = 16_000,
        apiKey: String,
        model: GeminiModel = .transcriptionDefault,
        language: String = "pt-BR",
        glossary: String = ""
    ) async throws -> String {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tx-gemini-\(UUID().uuidString).wav")
        try writeWav(samples: samples, sampleRate: Int(sampleRate), to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await transcribe(
            audioPath: tempURL,
            apiKey: apiKey,
            model: model,
            language: language,
            glossary: glossary
        )
    }

    // MARK: - Prompt

    private func buildSegmentedPrompt(language: String, glossary: String) -> String {
        var lines: [String] = []
        lines.append("Transcreva o áudio em \(language) palavra por palavra, segmentado por turnos de fala.")
        lines.append("Cada segmento deve corresponder a uma fala contínua de uma pessoa, frase ou parágrafo curto (15-40s no máximo).")
        lines.append("Quebre em segmentos menores quando houver pausa longa, mudança de assunto ou de interlocutor.")
        lines.append("Mantenha siglas técnicas em maiúsculas (PDV, BFF, MDM, JWT, OAuth, EntraID, SSO, API, BFF).")
        lines.append("Não comente, não resuma, não adicione cabeçalhos.")
        lines.append("Retorne APENAS o JSON com array de segmentos.")
        let trimmed = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append("Vocabulário esperado:")
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n")
    }

    private func buildPrompt(language: String, glossary: String) -> String {
        var lines: [String] = []
        lines.append("Transcreva o áudio em \(language) literalmente, palavra por palavra.")
        lines.append("Não resuma, não comente, não adicione cabeçalhos.")
        lines.append("Pontue corretamente. Mantenha siglas técnicas em maiúsculas (PDV, BFF, MDM, JWT, OAuth, EntraID, SSO).")
        lines.append("Retorne APENAS o texto transcrito, sem aspas, sem explicações.")
        let trimmed = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append("Vocabulário esperado:")
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - REST

    private func callGemini(
        apiKey: String,
        model: GeminiModel,
        audioMime: String,
        audioBase64: String,
        prompt: String
    ) async throws -> String {
        guard let url = URL(string: GeminiModel.endpoint(for: model)) else {
            throw GeminiTranscriptionError.invalidConfiguration("URL inválida")
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        [
                            "inline_data": [
                                "mime_type": audioMime,
                                "data": audioBase64
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.0,
                "maxOutputTokens": 8192,
                "responseMimeType": "text/plain",
                // Gemini 2.5 Flash gasta tokens em "thinking" antes de emitir
                // saída. Pra transcrição (tarefa direta), thinking come todo o
                // budget e devolve `parts` vazio. thinkingBudget=0 desativa.
                "thinkingConfig": [
                    "thinkingBudget": 0
                ]
            ]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 300
        let request = req

        return try await runWithRetry(label: "callGemini") {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GeminiTranscriptionError.networkError("Resposta inválida")
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                TxLogger.transcription.error("Gemini \(http.statusCode) body: \(body, privacy: .public)")
                dbg("[gemini] HTTP \(http.statusCode) body=\(body.prefix(500))")
                throw GeminiTranscriptionError.apiError(http.statusCode, body)
            }
            return try self.parseGeminiResponse(data)
        }
    }

    /// Wrapper de retry com backoff exponencial (3 tentativas: 0s, 800ms, 2400ms).
    /// Cobre cold-starts e 5xx transientes do Gemini. 4xx não-recuperáveis (400,
    /// 401, 404) propagam imediato. 403 e 429 retentam (cota efêmera/quota burst).
    private func runWithRetry<T: Sendable>(label: String, _ op: @Sendable () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<3 {
            if attempt > 0 {
                let delayMs = UInt64(800 * (1 << (attempt - 1)))
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                dbg("[gemini] \(label) retry #\(attempt) após \(delayMs)ms")
            }
            do {
                return try await op()
            } catch let error as GeminiTranscriptionError {
                if case .apiError(let code, let body) = error {
                    // 403 PERMISSION_DENIED é permanente (projeto banido/sem
                    // billing/API desabilitada). Não retenta — propaga já pra
                    // fallback Whisper rápido.
                    if code == 403 && body.contains("PERMISSION_DENIED") {
                        throw error
                    }
                    if code == 429 || code >= 500 {
                        lastError = error
                        continue
                    }
                }
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError ?? GeminiTranscriptionError.networkError("Retry falhou sem erro registrado")
    }

    private func callGeminiSegmented(
        apiKey: String,
        model: GeminiModel,
        audioMime: String,
        audioBase64: String,
        prompt: String
    ) async throws -> [GeminiTranscribedSegment] {
        guard let url = URL(string: GeminiModel.endpoint(for: model)) else {
            throw GeminiTranscriptionError.invalidConfiguration("URL inválida")
        }

        let schema: [String: Any] = [
            "type": "ARRAY",
            "items": [
                "type": "OBJECT",
                "properties": [
                    "startMs": ["type": "INTEGER"],
                    "endMs": ["type": "INTEGER"],
                    "text": ["type": "STRING"]
                ],
                "required": ["startMs", "endMs", "text"]
            ]
        ]

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        [
                            "inline_data": [
                                "mime_type": audioMime,
                                "data": audioBase64
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.0,
                "maxOutputTokens": 16384,
                "responseMimeType": "application/json",
                "responseSchema": schema,
                "thinkingConfig": [
                    "thinkingBudget": 0
                ]
            ]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 600
        let request = req

        return try await runWithRetry(label: "callGeminiSegmented") {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GeminiTranscriptionError.networkError("Resposta inválida")
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                TxLogger.transcription.error("Gemini segmented \(http.statusCode) body: \(body, privacy: .public)")
                dbg("[gemini-seg] HTTP \(http.statusCode) body=\(body.prefix(500))")
                throw GeminiTranscriptionError.apiError(http.statusCode, body)
            }
            let raw = try self.parseGeminiResponse(data)
            guard let payload = raw.data(using: .utf8) else {
                throw GeminiTranscriptionError.parseError("Payload UTF-8 inválido")
            }
            do {
                return try JSONDecoder().decode([GeminiTranscribedSegment].self, from: payload)
            } catch {
                throw GeminiTranscriptionError.parseError("JSON segmentos inválido: \(raw.prefix(200))")
            }
        }
    }

    nonisolated private func parseGeminiResponse(_ data: Data) throws -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let first = candidates.first
        else {
            let raw = String(data: data, encoding: .utf8) ?? "?"
            throw GeminiTranscriptionError.parseError("Resposta inesperada: \(raw.prefix(300))")
        }
        // `parts` ausente é resposta vazia legítima (modelo não emitiu nada).
        // Retorna string vazia em vez de propagar parseError — caller decide
        // se trata como falha (transcrição vazia → fallback Whisper).
        guard
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else {
            return ""
        }
        return text
    }

    // MARK: - WAV writer

    /// Escreve um WAV PCM 16-bit signed little-endian. Compatível com Gemini.
    nonisolated private func writeWav(samples: [Float], sampleRate: Int, to url: URL) throws {
        let channels: Int = 1
        let bitsPerSample: Int = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * blockAlign

        var data = Data()
        // RIFF header
        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(36 + dataSize).littleEndianData)
        data.append("WAVE".data(using: .ascii)!)
        // fmt chunk
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData)        // PCM
        data.append(UInt16(channels).littleEndianData)
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(UInt32(byteRate).littleEndianData)
        data.append(UInt16(blockAlign).littleEndianData)
        data.append(UInt16(bitsPerSample).littleEndianData)
        // data chunk
        data.append("data".data(using: .ascii)!)
        data.append(UInt32(dataSize).littleEndianData)
        // samples PCM16
        var pcm = Data(capacity: dataSize)
        for sample in samples {
            let clipped = max(-1.0, min(1.0, sample))
            let intVal = Int16(clipped * 32767.0)
            pcm.append(intVal.littleEndianData)
        }
        data.append(pcm)
        try data.write(to: url)
    }

    nonisolated private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mp3"
        case "m4a", "mp4": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "aiff", "aif": return "audio/aiff"
        default: return "audio/mp4"
        }
    }
}

// MARK: - Segments

/// Segmento estruturado retornado pelo Gemini em modo `transcribeSegmented`.
public struct GeminiTranscribedSegment: Codable, Sendable, Hashable {
    public let startMs: Int
    public let endMs: Int
    public let text: String
}

// MARK: - Errors

public enum GeminiTranscriptionError: LocalizedError {
    case missingApiKey
    case fileTooLarge(Int)
    case invalidConfiguration(String)
    case networkError(String)
    case apiError(Int, String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "Chave Gemini não configurada — Configurações > API."
        case .fileTooLarge(let bytes):
            let mb = Double(bytes) / 1_048_576
            return String(format: "Áudio grande demais (%.1f MB) — limite inline 18 MB. Use Whisper local.", mb)
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

// MARK: - Helpers

private extension UInt32 {
    var littleEndianData: Data {
        var le = self.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt32>.size)
    }
}

private extension UInt16 {
    var littleEndianData: Data {
        var le = self.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt16>.size)
    }
}

private extension Int16 {
    var littleEndianData: Data {
        var le = self.littleEndian
        return Data(bytes: &le, count: MemoryLayout<Int16>.size)
    }
}
