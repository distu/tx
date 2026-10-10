import Foundation
@preconcurrency import WhisperKit

public actor TranscriptionEngine {
    public private(set) var isModelReady: Bool = false
    public private(set) var downloadProgress: Double = 0
    public private(set) var currentModel: WhisperModel

    private var whisperKit: WhisperKit?
    private var isLoading = false
    private var activeUsers = 0
    private var unloadRequested = false

    public func beginUse() async throws {
        try await loadModel()
        activeUsers += 1
    }

    public func endUse() {
        activeUsers = max(0, activeUsers - 1)
        if activeUsers == 0 { unloadModel() }
    }

    public func unloadModel() {
        unloadRequested = true
        guard activeUsers == 0, !isLoading else { return }
        whisperKit = nil
        isModelReady = false
        downloadProgress = 0
        TxLogger.transcription.info("WhisperKit unloaded from RAM; disk cache retained")
    }

    public static let preferredModelKey = "tx.transcription.model"

    public init(model: WhisperModel? = nil) {
        if let model {
            self.currentModel = model
        } else if let saved = UserDefaults.standard.string(forKey: Self.preferredModelKey),
                  let resolved = WhisperModel(rawValue: saved) {
            self.currentModel = resolved
        } else {
            self.currentModel = .default
        }
    }

    public func loadModel(_ model: WhisperModel? = nil) async throws {
        let target = model ?? currentModel
        while isLoading {
            try await Task.sleep(for: .milliseconds(100))
        }
        if isModelReady, whisperKit != nil, currentModel == target {
            unloadRequested = false
            return
        }
        guard activeUsers == 0 else {
            throw TxError.invalidState("Aguarde a transcrição atual antes de trocar de modelo")
        }
        isLoading = true
        defer {
            isLoading = false
            if unloadRequested && activeUsers == 0 { unloadModel() }
        }
        unloadRequested = false
        self.currentModel = target
        UserDefaults.standard.set(target.rawValue, forKey: Self.preferredModelKey)
        isModelReady = false

        // `modelFolder` + `download: true` são mutuamente exclusivos no WhisperKit:
        // se `modelFolder` está setado, o download é ignorado. Usamos `downloadBase`
        // e deixamos o WhisperKit resolver o diretório-folha com os .mlmodelc.
        let config = WhisperKitConfig(
            model: target.rawValue,
            downloadBase: TxPaths.whisperCacheRoot,
            modelRepo: "argmaxinc/whisperkit-coreml",
            verbose: false,
            logLevel: .info,
            prewarm: true,
            load: true,
            download: true
        )
        TxLogger.transcription.info("Loading WhisperKit model \(target.rawValue, privacy: .public) (downloadBase=\(TxPaths.whisperCacheRoot.path, privacy: .public))")
        whisperKit = try await WhisperKit(config)
        isModelReady = true
        TxLogger.transcription.info("WhisperKit model loaded: \(target.rawValue, privacy: .public)")
    }

    public func transcribe(session: Session) async throws -> [TranscriptSegment] {
        guard isModelReady, let whisperKit else {
            throw TxError.modelNotReady
        }
        guard session.appAudioPath != nil || session.micAudioPath != nil else {
            throw TxError.transcriptionFailure("Sessão sem arquivos de áudio")
        }

        let appSegments = try await transcribeChannel(
            path: session.appAudioPath,
            sessionId: session.id,
            speaker: .others,
            channel: .app,
            whisperKit: whisperKit
        )
        let micSegments = try await transcribeChannel(
            path: session.micAudioPath,
            sessionId: session.id,
            speaker: .you,
            channel: .mic,
            whisperKit: whisperKit
        )

        let merged = (appSegments + micSegments).sorted { $0.startMs < $1.startMs }
        return merged
    }

    private func transcribeChannel(
        path: URL?,
        sessionId: UUID,
        speaker: TranscriptSegment.Speaker,
        channel: TranscriptSegment.Channel,
        whisperKit: WhisperKit
    ) async throws -> [TranscriptSegment] {
        guard let url = path else { return [] }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        // Threshold baixo (5KB ~= 1s áudio AAC) — anteriormente 50KB cortava
        // canais válidos quando ProcessTap pega Chrome helper com pouco output.
        // Vale tentar transcrever; Whisper devolve vazio se não houver voz.
        if size == 0 {
            throw TxError.transcriptionFailure("Canal \(channel.rawValue) ausente ou vazio")
        }

        let activity = try AudioActivityIndex(audioURL: url)
        if !activity.hasActivity {
            TxLogger.transcription.info("Canal \(channel.rawValue, privacy: .public) sem sinal; ASR ignorado")
            return []
        }

        do {
            let items = try await whisperKit.transcribe(
                audioPath: url.path,
                decodeOptions: Self.decodeOptions(language: "pt")
            )
            return Self.extractSegments(
                results: items,
                sessionId: sessionId,
                speaker: speaker,
                channel: channel
            ).filter { activity.hasActivity(startMs: $0.startMs, endMs: $0.endMs) }
        } catch {
            TxLogger.transcription.error("Canal \(channel.rawValue, privacy: .public) falhou: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Transcreve um arquivo de áudio em disco. Usado para retry de ditados
    /// falhos que persistiram o áudio mas não o texto.
    public func transcribe(audioPath: String, language: String = "pt") async throws -> String {
        guard isModelReady, let whisperKit else {
            throw TxError.modelNotReady
        }
        let results = try await whisperKit.transcribe(
            audioPath: audioPath,
            decodeOptions: Self.dictationDecodeOptions(language: language)
        )
        let joined = results
            .map { Self.cleanSpecialTokens($0.text) }
            .joined(separator: " ")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcreve com decoding options mais permissivas. Usado no retry quando
    /// a primeira tentativa retornou vazio — aceita hipóteses mais fracas.
    public func transcribePermissive(audioArray: [Float], language: String = "pt") async throws -> String {
        guard isModelReady, let whisperKit else {
            throw TxError.modelNotReady
        }
        let results = try await whisperKit.transcribe(
            audioArray: audioArray,
            decodeOptions: Self.permissiveDecodeOptions(language: language)
        )
        TxLogger.transcription.info("permissive: \(results.count) resultados")
        for r in results {
            TxLogger.transcription.info("permissive chunk: text=\"\(r.text, privacy: .public)\" segments=\(r.segments.count)")
        }
        let joined = results
            .map { Self.cleanSpecialTokens($0.text) }
            .joined(separator: " ")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Modo permissivo MÁXIMO: desliga TODOS os filtros que rejeitam output.
    /// Os defaults do WhisperKit (noSpeechThreshold=0.6, logProbThreshold=-1.0,
    /// firstTokenLogProbThreshold=-1.5, compressionRatioThreshold=2.4) descartam
    /// silenciosamente áudios curtos ou com início hesitante. Passando `nil`
    /// para cada um, nenhum resultado é bloqueado pelo VAD/confiança.
    private static func permissiveDecodeOptions(language: String) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            suppressBlank: false,
            compressionRatioThreshold: nil,
            logProbThreshold: nil,
            firstTokenLogProbThreshold: nil,
            noSpeechThreshold: nil
        )
    }

    /// Transcreve um buffer PCM mono float32 a 16 kHz já convertido.
    /// Usado pelo ditado global (curto, sem arquivo em disco).
    ///
    /// Força `language` no DecodingOptions E usa `usePrefillPrompt: true`
    /// para garantir que o token `<|pt|>` seja inserido antes do decoder
    /// começar — sem isso, o Whisper pode "cair" em inglês em áudios curtos.
    public func transcribe(audioArray: [Float], language: String = "pt") async throws -> String {
        guard isModelReady, let whisperKit else {
            throw TxError.modelNotReady
        }
        let results = try await whisperKit.transcribe(
            audioArray: audioArray,
            decodeOptions: Self.dictationDecodeOptions(language: language)
        )
        TxLogger.transcription.info("dict strict: \(results.count) resultados, samples=\(audioArray.count)")
        for r in results {
            TxLogger.transcription.info("dict chunk: text=\"\(r.text, privacy: .public)\" segments=\(r.segments.count)")
        }
        let joined = results
            .map { Self.cleanSpecialTokens($0.text) }
            .joined(separator: " ")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Opções específicas para o ditado global:
    /// - `usePrefillPrompt: true` força tokens `<|pt|><|transcribe|><|notimestamps|>`
    ///   antes do decoder, travando o idioma.
    /// - `detectLanguage: false` impede heurística que pode divergir em áudio curto.
    /// - `suppressBlank: true` evita hipóteses vazias.
    /// - `temperature: 0` produz saída determinística.
    /// Opções do ditado ao vivo. `noSpeechThreshold: nil` desativa o filtro
    /// de VAD interno do WhisperKit — áudios curtos com um leve delay no
    /// começo (usuário ainda pensando) estavam sendo descartados como
    /// silêncio mesmo com peak=0.7+. `temperatureFallbackCount: 2` permite
    /// 2 retentativas com temperatura maior antes de desistir.
    private static func dictationDecodeOptions(language: String) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            suppressBlank: true,
            noSpeechThreshold: nil
        )
    }

    private static func decodeOptions(language: String, wordTimestamps: Bool = true) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            wordTimestamps: wordTimestamps
        )
    }

    private static func extractSegments(
        results: [TranscriptionResult],
        sessionId: UUID,
        speaker: TranscriptSegment.Speaker,
        channel: TranscriptSegment.Channel
    ) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for result in results {
            for segment in result.segments {
                let text = cleanSpecialTokens(segment.text)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(
                    sessionId: sessionId,
                    speaker: speaker,
                    channel: channel,
                    text: text,
                    startMs: Int(segment.start * 1000),
                    endMs: Int(segment.end * 1000),
                    confidence: segment.avgLogprob.isNaN ? nil : Float(segment.avgLogprob)
                ))
            }
        }
        return segments
    }

    /// Remove tokens especiais do Whisper (`<|startoftranscript|>`, `<|pt|>`, `<|0.00|>`, etc.)
    /// que às vezes vazam para o texto dos segmentos.
    private static func cleanSpecialTokens(_ raw: String) -> String {
        var text = raw
        if let regex = try? NSRegularExpression(pattern: "<\\|[^|>]*\\|>", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
