import Foundation
import Observation
import AppKit
import AVFoundation
import CoreAudio
import TxCore

/// Orquestra o ciclo de ditado:
/// hotkey -> captura mic -> transcribe -> paste no app em foco -> persist.
///
/// Singleton injetado em `AppState`. Toda a UI observa `state` e `waveformLevels`.
@Observable
@MainActor
public final class DictationCoordinator {
    public private(set) var state: DictationState = .idle
    public private(set) var waveformLevels: [Float] = Array(repeating: 0, count: 48)
    public private(set) var lastError: String?
    /// UUID do último ditado que falhou. Usado pelo HUD para oferecer botão
    /// de reprocessamento direto sem abrir o Dashboard.
    public private(set) var lastFailedDictationId: UUID?
    public private(set) var isRetrying: Bool = false

    public var hotkey: GlobalHotkeyManager?
    public var micTap: MicrophoneTap?

    private let transcription: TranscriptionEngine
    private let geminiTranscription: GeminiTranscriptionEngine
    private let store: DictationStore

    private var audioBuffers: [AVAudioPCMBuffer] = []
    private var recordingStartedAt: Date?
    private var currentMode: Dictation.Mode = .pushToTalk

    private var hotkeyTask: Task<Void, Never>?
    private var micTask: Task<Void, Never>?

    private static let minDurationMs: Int = 500
    private static let waveformWindow: Int = 48

    public init(
        transcription: TranscriptionEngine,
        geminiTranscription: GeminiTranscriptionEngine,
        store: DictationStore
    ) {
        self.transcription = transcription
        self.geminiTranscription = geminiTranscription
        self.store = store
    }

    // Não expomos deinit: em @MainActor @Observable, deinit é nonisolated.
    // Tasks são canceladas via stopAll() ou automaticamente pelo ARC quando
    // nenhuma referência sobrevive ao AppState.

    // MARK: - Bootstrap

    /// Instala o hotkey tap e inicia o loop de eventos. Chamar uma vez no launch
    /// após garantir Input Monitoring. Se não instalado, persiste `lastError`.
    public func start() {
        if hotkey == nil {
            hotkey = GlobalHotkeyManager()
        }
        guard let hotkey else { return }
        do {
            try hotkey.install()
        } catch {
            lastError = error.localizedDescription
            TxLogger.app.error("DictationCoordinator.start: \(error.localizedDescription, privacy: .public)")
            return
        }

        hotkeyTask?.cancel()
        hotkeyTask = Task { [weak self, stream = hotkey.stream] in
            for await event in stream {
                guard let self else { break }
                await self.handle(event: event)
            }
        }
        TxLogger.app.info("DictationCoordinator: pronto para ditar")
    }

    public func stopAll() {
        hotkey?.uninstall()
        hotkeyTask?.cancel()
        micTask?.cancel()
        micTap?.stop()
        state = .idle
    }

    // MARK: - Hotkey events

    private func handle(event: HotkeyEvent) async {
        switch event {
        case .holdStarted:
            switch state {
            case .idle, .error:
                state = .idle
                hotkey?.isRecording = false
                await startRecording(mode: .pushToTalk)
            case .recording(let mode, _) where mode == .locked:
                await finishRecording()
            default:
                break
            }

        case .holdEnded:
            if case .recording(let mode, _) = state, mode == .pushToTalk {
                await finishRecording()
            }

        case .doubleTap:
            switch state {
            case .idle, .error:
                state = .idle
                hotkey?.isRecording = false
                await startRecording(mode: .locked)
            case .recording(let mode, _) where mode == .locked:
                await finishRecording()
            default:
                break
            }

        case .escapePressed:
            switch state {
            case .recording:
                await cancelRecording()
            case .error:
                state = .idle
                hotkey?.isRecording = false
            default:
                break
            }
        }
    }

    /// Encerra modo travado via clique no HUD.
    public func stopLocked() {
        guard case .recording(let mode, _) = state, mode == .locked else { return }
        Task { await finishRecording() }
    }

    public func cancelFromHUD() {
        guard case .recording = state else { return }
        Task { await cancelRecording() }
    }

    /// Inicia ditado travado (locked) manualmente via clique no HUD — fallback
    /// para quando o usuário não quer ou não pode usar a Fn.
    public func startManual() {
        guard case .idle = state else { return }
        Task { await startRecording(mode: .locked) }
    }

    // MARK: - Recording

    private func startRecording(mode: Dictation.Mode) async {
        DictationDebugLog.shared.info("rec", "start mode=\(mode.rawValue)")
        let storedDeviceID = UserDefaults.standard.integer(forKey: "tx.audio.micDeviceID")
        let micDeviceID: AudioDeviceID? = storedDeviceID > 0 ? AudioDeviceID(storedDeviceID) : nil
        let tap = MicrophoneTap(preferredDeviceID: micDeviceID)
        self.micTap = tap
        do {
            try tap.start()
        } catch {
            state = .error("Microfone indisponível: \(error.localizedDescription)")
            DictationDebugLog.shared.error("rec", "mic falhou: \(error.localizedDescription)")
            return
        }

        audioBuffers.removeAll(keepingCapacity: true)
        waveformLevels = Array(repeating: 0, count: Self.waveformWindow)
        recordingStartedAt = Date()
        currentMode = mode
        state = .recording(mode: mode, startedAt: recordingStartedAt!)
        hotkey?.isRecording = true
        DictationDebugLog.shared.success("rec", "mic ativo")

        micTask?.cancel()
        micTask = Task { [weak self, stream = tap.stream] in
            for await box in stream {
                guard let self else { break }
                self.ingest(buffer: box.buffer)
            }
        }
    }

    private func ingest(buffer: AVAudioPCMBuffer) {
        audioBuffers.append(buffer)
        let db = AudioLevelMeter.rmsLevel(buffer: buffer)
        let level = AudioLevelMeter.normalized(fromDB: db)
        var next = waveformLevels
        next.removeFirst()
        next.append(level)
        waveformLevels = next
    }

    private func finishRecording() async {
        let buffers = audioBuffers
        let startedAt = recordingStartedAt ?? Date()
        let mode = currentMode
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        stopMic()
        DictationDebugLog.shared.info("rec", "stop, dur=\(durationMs)ms buffers=\(buffers.count)")

        guard durationMs >= Self.minDurationMs else {
            DictationDebugLog.shared.warn("rec", "descartado — duração < \(Self.minDurationMs)ms")
            state = .idle
            hotkey?.isRecording = false
            audioBuffers.removeAll()
            return
        }

        state = .transcribing(durationMs: durationMs)
        let (samples, normInfo) = PCMResampler.toMono16kWithInfo(buffers: buffers)
        audioBuffers.removeAll()
        let seconds = Double(samples.count) / PCMResampler.targetSampleRate

        let peakAbs = samples.map { abs($0) }.max() ?? 0
        let rms = sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(samples.count, 1)))
        let rmsDb = rms > 0 ? 20 * log10(rms) : -160
        let gainInfo = normInfo.gain > 1.01
            ? " gain=\(String(format: "%.2fx", normInfo.gain)) peakBefore=\(String(format: "%.3f", normInfo.peakBefore))"
            : ""
        DictationDebugLog.shared.info("asr", "samples=\(samples.count) (\(String(format: "%.2f", seconds))s mono 16k) peak=\(String(format: "%.3f", peakAbs)) rmsDB=\(String(format: "%.1f", rmsDb))\(gainInfo)")
        dbg("[dict] samples=\(samples.count) seconds=\(String(format: "%.2f", seconds)) peak=\(String(format: "%.3f", peakAbs)) rmsDB=\(String(format: "%.1f", rmsDb))\(gainInfo)")

        // Lê preferências dinâmicas: Gemini API ou Whisper local?
        let useGemini = UserDefaults.standard.bool(forKey: GeminiModel.useGeminiTranscriptionKey)
        let geminiKey = GeminiCredentialStore.load()
        let geminiModel = GeminiModel(
            rawValue: UserDefaults.standard.string(forKey: GeminiModel.transcriptionModelKey)
                ?? GeminiModel.transcriptionDefault.rawValue
        ) ?? .transcriptionDefault

        if useGemini && geminiKey.isEmpty {
            state = .error("Chave Gemini ausente — Configurações > API")
            try? await Task.sleep(for: .seconds(2))
            state = .idle
            hotkey?.isRecording = false
            return
        }

        let dictationId = UUID()
        let audioURL = TxPaths.dictationAudioURL(id: dictationId, startedAt: startedAt)
        let savedAudioPath = persistAudio(buffers: buffers, to: audioURL)
        var modelAcquired = false
        defer { if modelAcquired { Task { await transcription.endUse() } } }

        do {
            let t0 = Date()
            var text: String = ""
            if useGemini {
                dbg("[dict] usando Gemini \(geminiModel.rawValue)")
                var geminiFailReason: String? = nil
                do {
                    text = try await geminiTranscription.transcribe(
                        audioArray: samples,
                        sampleRate: PCMResampler.targetSampleRate,
                        apiKey: geminiKey,
                        model: geminiModel,
                        language: "pt-BR",
                        glossary: DictationVocabulary.load().terms
                    )
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        geminiFailReason = "Gemini retornou vazio (thinking budget consumiu output)"
                    }
                } catch {
                    geminiFailReason = error.localizedDescription
                }
                if let reason = geminiFailReason {
                    // Fallback automático: Gemini falhou ou retornou vazio.
                    // Tenta Whisper local pra não perder o ditado.
                    dbg("[dict] Gemini falhou (\(reason.prefix(120))), fallback Whisper")
                    DictationDebugLog.shared.warn("asr", "Gemini falhou, fallback Whisper: \(reason.prefix(160))")
                    try await transcription.beginUse()
                    modelAcquired = true
                    text = try await transcription.transcribe(audioArray: samples, language: "pt")
                }
            } else {
                try await transcription.beginUse()
                modelAcquired = true
                text = try await transcription.transcribe(audioArray: samples, language: "pt")
            }
            let asrMs = Int(Date().timeIntervalSince(t0) * 1000)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            DictationDebugLog.shared.success("asr", "\(asrMs)ms -> \"\(trimmed.prefix(80))\"")

            guard !trimmed.isEmpty else {
                let diagnostic = "peak=\(String(format: "%.2f", peakAbs)) rmsDB=\(String(format: "%.0f", rmsDb)) gain=\(String(format: "%.1fx", normInfo.gain))"
                DictationDebugLog.shared.warn("asr", "transcrição vazia \(diagnostic) — áudio salvo em \(savedAudioPath?.path ?? "nil")")
                persistFailedDictation(
                    id: dictationId,
                    startedAt: startedAt,
                    durationMs: durationMs,
                    mode: mode,
                    audioPath: savedAudioPath,
                    reason: "Transcrição vazia (\(diagnostic))"
                )
                state = .error("Transcrição vazia — veja Histórico (clique □ no HUD)")
                try? await Task.sleep(for: .seconds(1))
                state = .idle
                hotkey?.isRecording = false
                return
            }

            state = .pasting(text: trimmed)

            let (targetApp, targetBundle) = currentFrontmostApp()
            DictationDebugLog.shared.info("paste", "alvo: \(targetApp ?? "?") (\(targetBundle ?? "?"))")

            // Checa Accessibility antes de tentar Cmd+V.
            if !PasteSimulator.hasAccessibilityPermission() {
                DictationDebugLog.shared.error("paste",
                    "Accessibility NÃO concedida — texto fica no clipboard, cole manualmente com Cmd+V")
                // Deixa o texto no clipboard mesmo assim.
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(trimmed, forType: .string)
                lastError = "Conceda permissão de Acessibilidade para colar automaticamente"
            } else {
                do {
                    try await ClipboardGuardian.shared.pasteText(trimmed)
                    DictationDebugLog.shared.success("paste", "Cmd+V enviado")
                } catch {
                    DictationDebugLog.shared.error("paste", "falhou: \(error.localizedDescription)")
                    lastError = error.localizedDescription
                }
            }

            let dictation = Dictation(
                id: dictationId,
                startedAt: startedAt,
                durationMs: durationMs,
                wordCount: Dictation.computeWordCount(trimmed),
                wpm: Dictation.computeWpm(
                    words: Dictation.computeWordCount(trimmed),
                    durationMs: durationMs
                ),
                text: trimmed,
                mode: mode,
                targetApp: targetApp,
                targetBundle: targetBundle,
                pasted: true,
                canceled: false,
                audioPath: savedAudioPath
            )
            do {
                try store.insert(dictation)
                DictationDebugLog.shared.success("store", "persistido id=\(dictation.id.uuidString.prefix(8))")
            } catch {
                DictationDebugLog.shared.error("store", "insert falhou: \(error.localizedDescription)")
            }
        } catch {
            DictationDebugLog.shared.error("asr", "transcribe falhou: \(error.localizedDescription)")
            persistFailedDictation(
                id: dictationId,
                startedAt: startedAt,
                durationMs: durationMs,
                mode: mode,
                audioPath: savedAudioPath,
                reason: error.localizedDescription
            )
            state = .error(error.localizedDescription)
            try? await Task.sleep(for: .seconds(2))
        }

        state = .idle
        hotkey?.isRecording = false
    }

    private func cancelRecording() async {
        stopMic()
        audioBuffers.removeAll()
        state = .idle
        hotkey?.isRecording = false
        TxLogger.app.info("DictationCoordinator: ditado cancelado (ESC)")
    }

    private func stopMic() {
        micTask?.cancel()
        micTask = nil
        micTap?.stop()
        micTap = nil
    }

    private func persistAudio(buffers: [AVAudioPCMBuffer], to url: URL) -> URL? {
        guard let first = buffers.first else { return nil }
        do {
            let writer = try AudioFileWriter(
                url: url,
                targetSampleRate: 16_000,
                channels: 1
            )
            for buffer in buffers {
                try writer.write(buffer)
            }
            writer.close()
            dbg("[dict] audio salvo: \(url.lastPathComponent) buffers=\(buffers.count) fmt=\(first.format)")
            return url
        } catch {
            DictationDebugLog.shared.error("store", "falha salvando áudio: \(error.localizedDescription)")
            dbg("[dict] falha salvando áudio: \(error.localizedDescription)")
            return nil
        }
    }

    private func persistFailedDictation(
        id: UUID,
        startedAt: Date,
        durationMs: Int,
        mode: Dictation.Mode,
        audioPath: URL?,
        reason: String
    ) {
        let failed = Dictation(
            id: id,
            startedAt: startedAt,
            durationMs: durationMs,
            wordCount: 0,
            wpm: 0,
            text: "[falhou: \(reason)]",
            mode: mode,
            targetApp: nil,
            targetBundle: nil,
            pasted: false,
            canceled: false,
            audioPath: audioPath
        )
        do {
            try store.insert(failed)
            lastFailedDictationId = audioPath != nil ? id : nil
            DictationDebugLog.shared.warn("store", "ditado falho persistido id=\(id.uuidString.prefix(8)) audio=\(audioPath?.lastPathComponent ?? "nil")")
        } catch {
            DictationDebugLog.shared.error("store", "persist falho: \(error.localizedDescription)")
        }
    }

    /// Reprocessa o último ditado que falhou. Lê o áudio do disco, aplica
    /// normalização e chama o Whisper novamente. Usado pelo botão no HUD.
    public func retryLastFailed() async {
        guard let id = lastFailedDictationId, !isRetrying else { return }

        isRetrying = true
        var modelAcquired = false
        defer { if modelAcquired { Task { await transcription.endUse() } } }
        state = .transcribing(durationMs: 0)
        defer {
            isRetrying = false
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if case .transcribing = state { state = .idle }
            }
        }

        let dictation: Dictation?
        do {
            dictation = try store.find(id: id)
        } catch {
            DictationDebugLog.shared.error("retry", "find falhou: \(error.localizedDescription)")
            state = .error("Falha buscando ditado: \(error.localizedDescription)")
            return
        }

        guard let d = dictation, let audio = d.audioPath else {
            state = .error("Áudio não encontrado")
            return
        }

        do {
            let samples = try await loadNormalizedSamplesForRetry(from: audio)
            guard !samples.isEmpty else {
                state = .error("Áudio vazio no disco")
                return
            }
            try await transcription.beginUse()
            modelAcquired = true
            var text = try await transcription
                .transcribe(audioArray: samples, language: "pt")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if text.isEmpty {
                DictationDebugLog.shared.info("retry", "tentando modo permissivo")
                text = try await transcription
                    .transcribePermissive(audioArray: samples, language: "pt")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if text.isEmpty {
                DictationDebugLog.shared.info("retry", "tentando audioPath direto")
                text = try await transcription
                    .transcribe(audioPath: audio.path, language: "pt")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard !text.isEmpty else {
                DictationDebugLog.shared.warn("retry", "Whisper retornou vazio em 3 modos")
                state = .error("Whisper vazio — ouça o áudio no Histórico")
                return
            }

            var updated = d
            updated.text = text
            updated.wordCount = Dictation.computeWordCount(text)
            updated.wpm = Dictation.computeWpm(words: updated.wordCount, durationMs: d.durationMs)
            try store.update(updated)
            lastFailedDictationId = nil

            // Cola no app em foco
            if PasteSimulator.hasAccessibilityPermission() {
                try await ClipboardGuardian.shared.pasteText(text)
            } else {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
            DictationDebugLog.shared.success("retry", "OK -> \"\(text.prefix(80))\"")
            state = .pasting(text: text)
            try? await Task.sleep(for: .milliseconds(800))
            state = .idle
        } catch {
            DictationDebugLog.shared.error("retry", "\(error.localizedDescription)")
            state = .error("Retry falhou: \(error.localizedDescription)")
        }
    }

    private func loadNormalizedSamplesForRetry(from url: URL) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: buffer)
        let result = PCMResampler.toMono16kWithInfo(buffers: [buffer])
        dbg("[retry] samples=\(result.samples.count) gain=\(String(format: "%.2fx", result.info.gain)) peakBefore=\(String(format: "%.3f", result.info.peakBefore)) peakAfter=\(String(format: "%.3f", result.info.peakAfter))")
        return result.samples
    }

    private func currentFrontmostApp() -> (String?, String?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName, app?.bundleIdentifier)
    }
}
