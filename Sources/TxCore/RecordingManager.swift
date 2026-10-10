import Foundation
import Observation
import CoreAudio
import AVFoundation
import AppKit

/// Fachada de alto nível para iniciar, pausar, parar e transcrever sessões.
/// Mantém a lista de `AudioPipeline` ativos e coordena persistência + transcrição.
@Observable
@MainActor
public final class RecordingManager {
    public private(set) var activePipelines: [UUID: AudioPipeline] = [:]
    public private(set) var transcribingSessionIds: Set<UUID> = []
    private var stoppingSessionIds: Set<UUID> = []

    public let database: DatabaseManager
    public let sessionRepository: SessionRepository
    public let segmentRepository: SegmentRepository
    public let projectManager: ProjectManager
    public let transcriptionEngine: TranscriptionEngine
    public let geminiTranscriptionEngine: GeminiTranscriptionEngine
    public let processDetector: ProcessDetector

    /// Estado de mute recente por reunião; uma associação ambígua nunca altera
    /// os microfones de várias sessões ao mesmo tempo.
    private var muteByMeeting: [String: (muted: Bool, at: Date)] = [:]
    private var accessibilityControlledSessions: Set<UUID> = []
    private var accessibilityMonitorTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        database: DatabaseManager,
        projectManager: ProjectManager,
        transcriptionEngine: TranscriptionEngine,
        geminiTranscriptionEngine: GeminiTranscriptionEngine,
        processDetector: ProcessDetector = ProcessDetector()
    ) {
        self.database = database
        self.sessionRepository = SessionRepository(database: database)
        self.segmentRepository = SegmentRepository(database: database)
        self.projectManager = projectManager
        self.transcriptionEngine = transcriptionEngine
        self.geminiTranscriptionEngine = geminiTranscriptionEngine
        self.processDetector = processDetector
    }

    public var activeSessionsCount: Int { activePipelines.count }

    /// Reexecuta a transcrição para uma sessão já gravada (útil pra retentar
    /// sessões que falharam porque o modelo não estava pronto).
    public func retryTranscription(sessionId: UUID) async throws {
        guard !transcribingSessionIds.contains(sessionId) else {
            throw TxError.invalidState("Transcrição já em andamento")
        }
        guard var session = try sessionRepository.find(id: sessionId) else {
            throw TxError.invalidState("Session \(sessionId.uuidString) não encontrada")
        }
        guard session.appAudioPath != nil || session.micAudioPath != nil else {
            throw TxError.invalidState("Sessão sem arquivos de áudio para retentar")
        }
        guard session.status != .recording && session.status != .paused else {
            throw TxError.invalidState("Pare a gravação antes de transcrever")
        }
        session.status = .transcribing
        try sessionRepository.update(session)
        transcribingSessionIds.insert(sessionId)

        Task.detached { [weak self] in
            await self?.runTranscription(for: session)
        }
    }

    public func startRecording(
        process: AudioProcess,
        title: String,
        projectId: UUID? = nil,
        meetingURL: URL? = nil,
        chromeProfileId: UUID? = nil,
        protectMeetingMic: Bool = false
    ) async throws -> Session {
        dbg("[rec] startRecording pid=\(process.pid) name=\(process.name) bundle=\(process.bundleId ?? "nil")")
        do {
            try await processDetector.validateHasActiveOutput(pid: process.pid)
            dbg("[rec] validateHasActiveOutput OK")
        } catch {
            dbg("[rec] validateHasActiveOutput FALHOU: \(error)")
            throw error
        }
        let root = ProcessArgsReader.captureGroupRoot(for: process.pid, bundleId: process.bundleId)
        if let root, activePipelines.values.contains(where: { $0.rootPID == root }) {
            throw TxError.invalidState("Esta instância já está sendo gravada. Abra outra instância do navegador para separar reuniões.")
        }

        // O título e o URL vêm da escolha exibida e reconfirmada no menu.
        // Uma janela em foco não identifica qual aba gerou o áudio do processo.
        let resolvedTitle = title

        let draft = SessionDraft(
            processName: process.name,
            processBundleId: process.bundleId,
            userDataDir: process.userDataDir,
            meetingURL: meetingURL,
            title: resolvedTitle
        )

        let inferredProjectId = projectId ?? projectManager.inferProject(for: draft)?.id

        let session = Session(
            projectId: inferredProjectId,
            title: resolvedTitle,
            processName: process.name,
            processPid: process.pid,
            startedAt: .now,
            status: .recording,
            chromeProfileId: chromeProfileId,
            meetingURL: meetingURL,
            transcriptModel: await transcriptionEngine.currentModel.rawValue
        )
        try sessionRepository.insert(session)

        let storedDeviceID = UserDefaults.standard.integer(forKey: "tx.audio.micDeviceID")
        let bundleIdDbg = Bundle.main.bundleIdentifier ?? "nil"
        dbg("[rec] UserDefaults micDeviceID=\(storedDeviceID) bundle=\(bundleIdDbg)")
        let micDeviceID: AudioDeviceID? = storedDeviceID > 0 ? AudioDeviceID(storedDeviceID) : nil

        let pipeline = AudioPipeline(
            pid: process.pid,
            bundleId: process.bundleId,
            processName: process.name,
            sessionId: session.id,
            startedAt: session.startedAt,
            micDeviceID: micDeviceID
        )
        let meetingKey = Self.meetingKey(meetingURL)
        if protectMeetingMic || meetingKey != nil {
            pipeline.protectMicUntilMeetState(hasAssociation: meetingKey != nil)
        }
        dbg("[rec] chamando pipeline.start()...")
        do {
            try await pipeline.start()
        } catch {
            var failed = session
            failed.status = .failed
            failed.endedAt = .now
            try? sessionRepository.update(failed)
            throw error
        }
        activePipelines[session.id] = pipeline
        // Se a extensão já reportou estado de mute antes do início da gravação,
        // aplica imediatamente — evita capturar áudio quando o user inicia
        // a call já mutado.
        if let key = meetingKey,
           let mute = muteByMeeting[key], mute.muted,
           Date().timeIntervalSince(mute.at) < 30 {
            pipeline.setMicMute(true)
            TxLogger.audio.info("Recording started with mic muted for meeting")
        }
        if let rootPID = pipeline.rootPID,
           let bundleID = NSRunningApplication(processIdentifier: rootPID)?.bundleIdentifier {
            if ["com.google.Chrome", "company.thebrowser.Browser", "com.apple.Safari"]
                .contains(bundleID), meetingURL != nil || protectMeetingMic {
                startBrowserMicMonitor(sessionId: session.id, processPID: rootPID,
                                       bundleID: bundleID, meetingURL: meetingURL,
                                       nativeTeams: false)
            } else if protectMeetingMic && bundleID.lowercased().hasPrefix("com.microsoft.teams")
                && MeetAccessibilityReader.isAvailable {
                startBrowserMicMonitor(sessionId: session.id, processPID: rootPID,
                                       bundleID: bundleID, meetingURL: nil,
                                       nativeTeams: true)
            }
        }
        dbg("[rec] GRAVANDO session=\(session.id) pid=\(process.pid)")

        TxLogger.audio.info("Started recording session \(session.id.uuidString) for PID \(process.pid)")
        return session
    }

    public func pauseRecording(sessionId: UUID) async {
        guard let pipeline = activePipelines[sessionId] else { return }
        await pipeline.pause()
        if var session = try? sessionRepository.find(id: sessionId) {
            session.status = .paused
            try? sessionRepository.update(session)
        }
    }

    public func resumeRecording(sessionId: UUID) async {
        guard let pipeline = activePipelines[sessionId] else { return }
        await pipeline.resume()
        if var session = try? sessionRepository.find(id: sessionId) {
            session.status = .recording
            try? sessionRepository.update(session)
        }
    }

    public func stopRecording(sessionId: UUID) async throws -> Session {
        TxLogger.audio.info("stopRecording called for session \(sessionId.uuidString, privacy: .public)")
        guard let pipeline = activePipelines[sessionId] else {
            throw TxError.invalidState("Nenhum pipeline ativo para \(sessionId.uuidString)")
        }
        guard stoppingSessionIds.insert(sessionId).inserted else {
            throw TxError.invalidState("Esta gravação já está sendo encerrada")
        }
        defer { stoppingSessionIds.remove(sessionId) }

        accessibilityMonitorTasks.removeValue(forKey: sessionId)?.cancel()

        let files = await pipeline.stop()
        activePipelines.removeValue(forKey: sessionId)
        accessibilityControlledSessions.remove(sessionId)
        TxLogger.audio.info("pipeline stopped, app=\(files?.appChannel.path ?? "nil", privacy: .public) mic=\(files?.micChannel.path ?? "nil", privacy: .public)")

        guard var session = try sessionRepository.find(id: sessionId) else {
            throw TxError.invalidState("Session \(sessionId.uuidString) não encontrada no banco")
        }
        session.endedAt = .now
        session.durationSeconds = session.endedAt?.timeIntervalSince(session.startedAt)
        session.appAudioPath = Self.validAudio(files?.appChannel)
        session.micAudioPath = Self.validAudio(files?.micChannel)
        session.playbackAudioPath = Self.validAudio(files?.playbackAudio)
        session.status = session.appAudioPath != nil || session.micAudioPath != nil ? .recorded : .failed
        try sessionRepository.update(session)

        if session.status == .recorded {
            // O arquivo já está finalizado; iniciar o Whisper somente agora
            // mantém o modelo fora da memória durante a gravação.
            do {
                try await retryTranscription(sessionId: sessionId)
                session.status = .transcribing
            } catch {
                // A mídia continua disponível para uma tentativa manual.
                TxLogger.transcription.error("Unable to start transcription after stop: \(error.localizedDescription, privacy: .public)")
            }
        }

        return session
    }

    /// Aplica o mute somente à reunião identificada pela extensão.
    /// Chamado pelo MeetBridgeServer quando a extensão detecta mudança de mute no Meet.
    public func setMicMute(_ muted: Bool, meetId: String?) {
        guard let key = Self.meetingKey(meetId) else { return }
        muteByMeeting[key] = (muted, .now)
        let matches = activePipelines.compactMap { sessionId, pipeline -> AudioPipeline? in
            guard !accessibilityControlledSessions.contains(sessionId) else { return nil }
            guard let session = try? sessionRepository.find(id: sessionId),
                  Self.meetingKey(session.meetingURL) == key else { return nil }
            return pipeline
        }
        if matches.count == 1 { matches[0].setMicMute(muted) }
        TxLogger.audio.info("RecordingManager: mute da reunião aplicado sem afetar outras sessões")
    }

    private func startBrowserMicMonitor(
        sessionId: UUID,
        processPID: pid_t,
        bundleID: String,
        meetingURL: URL?,
        nativeTeams: Bool
    ) {
        accessibilityControlledSessions.insert(sessionId)
        accessibilityMonitorTasks[sessionId] = Task { [weak self] in
            while !Task.isCancelled {
                let muted = await Task.detached(priority: .utility) {
                    if nativeTeams {
                        return MeetAccessibilityReader.teamsMicMuted(processPID: processPID, nativeApp: true)
                    }
                    if let scripted = await AppleScriptBridge.microphoneMuted(
                        browserBundleId: bundleID, meetingURL: meetingURL
                    ) {
                        return scripted
                    }
                    guard MeetAccessibilityReader.isAvailable else { return nil }
                    if let meetingURL {
                        return MeetAccessibilityReader.micMuted(browserPID: processPID, meetingURL: meetingURL)
                    }
                    return MeetAccessibilityReader.teamsMicMuted(processPID: processPID)
                }.value

                guard let self, let pipeline = self.activePipelines[sessionId] else { return }
                if let muted {
                    pipeline.setMicMute(muted)
                } else {
                    pipeline.setMeetMicStateUnknown()
                }

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private static func meetingKey(_ url: URL?) -> String? {
        guard let url, url.host == "meet.google.com" else { return nil }
        return meetingKey(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private static func meetingKey(_ meetId: String?) -> String? {
        guard let meetId, !meetId.isEmpty else { return nil }
        return meetId.lowercased()
    }

    private static func validAudio(_ url: URL?) -> URL? {
        guard let url,
              FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url),
              file.length > 0 else { return nil }
        return url
    }

    /// Atualiza participantes (e opcionalmente título) de uma sessão ativa ou recente.
    /// Chamado pelo MeetBridgeServer quando a extensão Chrome envia dados.
    public func updateParticipants(meetingURL: URL?, participants: [String], title: String?) {
        // Tenta encontrar sessão ativa que bata com a URL da reunião
        let activeSessionId = activePipelines.keys.first { sessionId in
            guard let session = try? sessionRepository.find(id: sessionId) else { return false }
            if let meetURL = meetingURL, let sessionURL = session.meetingURL {
                return meetURL.path == sessionURL.path
            }
            return false
        }

        guard let sessionId = activeSessionId,
              var session = try? sessionRepository.find(id: sessionId) else {
            TxLogger.audio.warning("updateParticipants: nenhuma sessão ativa encontrada")
            return
        }

        session.participants = participants
        if session.meetingURL == nil { session.meetingURL = meetingURL }
        if let newTitle = title, !newTitle.isEmpty {
            session.title = newTitle
        }

        do {
            try sessionRepository.update(session)
            TxLogger.audio.info("updateParticipants: session \(sessionId.uuidString, privacy: .public) -> \(participants.count) participantes")
        } catch {
            TxLogger.audio.error("updateParticipants failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runTranscription(for session: Session) async {
        TxLogger.transcription.info("runTranscription START for \(session.id.uuidString, privacy: .public)")
        do {
            // Para meetings usa flag dedicada (default OFF). Whisper local
            // produz segmentos por frase com timestamps reais, intercalando
            // mic/app cronologicamente. Gemini devolve 1 segmento gigante por
            // canal — perde fluxo da conversa.
            let useGemini = UserDefaults.standard.bool(forKey: GeminiModel.useGeminiMeetingsKey)
            let segments: [TranscriptSegment]
            if useGemini {
                TxLogger.transcription.info("Gemini path enabled")
                segments = try await transcribeViaGemini(session: session)
            } else {
                try await transcriptionEngine.beginUse()
                TxLogger.transcription.info("calling transcribe()…")
                do {
                    segments = try await transcriptionEngine.transcribe(session: session)
                    await transcriptionEngine.endUse()
                } catch {
                    await transcriptionEngine.endUse()
                    throw error
                }
            }
            TxLogger.transcription.info("transcribe() returned \(segments.count) segments; inserting…")
            try segmentRepository.replaceForSession(session.id, with: segments)

            if var updated = try sessionRepository.find(id: session.id) {
                updated.transcriptModel = useGemini
                    ? (UserDefaults.standard.string(forKey: GeminiModel.transcriptionModelKey)
                        ?? GeminiModel.transcriptionDefault.rawValue)
                    : await transcriptionEngine.currentModel.rawValue
                updated.status = .done
                try sessionRepository.update(updated)
            }
            transcribingSessionIds.remove(session.id)
            TxLogger.transcription.info("Session \(session.id.uuidString, privacy: .public) transcribed with \(segments.count) segments")
        } catch {
            TxLogger.transcription.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            if var updated = try? sessionRepository.find(id: session.id) {
                updated.status = .failed
                try? sessionRepository.update(updated)
            }
            transcribingSessionIds.remove(session.id)
        }
    }

    /// Transcreve canais (mic + app) via Gemini API. Cada canal vira UM
    /// segmento single-block (sem timestamps internos — Gemini não devolve
    /// segmentação por padrão). Speakers: mic → você, app → outros.
    private func transcribeViaGemini(session: Session) async throws -> [TranscriptSegment] {
        let apiKey = GeminiCredentialStore.load()
        guard !apiKey.isEmpty else {
            throw TxError.invalidState("Chave Gemini ausente — Configurações > API")
        }
        let model = GeminiModel(
            rawValue: UserDefaults.standard.string(forKey: GeminiModel.transcriptionModelKey)
                ?? GeminiModel.transcriptionDefault.rawValue
        ) ?? .transcriptionDefault

        var segments: [TranscriptSegment] = []

        if let url = session.micAudioPath, FileManager.default.fileExists(atPath: url.path) {
            let activity = try AudioActivityIndex(audioURL: url)
            if activity.hasActivity {
                let raw = try await geminiTranscriptionEngine.transcribeSegmented(
                audioPath: url, apiKey: apiKey, model: model, language: "pt-BR"
                )
                segments.append(contentsOf: raw.filter {
                    activity.hasActivity(startMs: $0.startMs, endMs: $0.endMs)
                }.map { seg in
                TranscriptSegment(
                    sessionId: session.id, speaker: .you, channel: .mic,
                    text: seg.text, startMs: seg.startMs, endMs: seg.endMs, confidence: nil
                )
                })
            }
        }
        if let url = session.appAudioPath, FileManager.default.fileExists(atPath: url.path) {
            let activity = try AudioActivityIndex(audioURL: url)
            if activity.hasActivity {
                let raw = try await geminiTranscriptionEngine.transcribeSegmented(
                audioPath: url, apiKey: apiKey, model: model, language: "pt-BR"
                )
                segments.append(contentsOf: raw.filter {
                    activity.hasActivity(startMs: $0.startMs, endMs: $0.endMs)
                }.map { seg in
                TranscriptSegment(
                    sessionId: session.id, speaker: .others, channel: .app,
                    text: seg.text, startMs: seg.startMs, endMs: seg.endMs, confidence: nil
                )
                })
            }
        }
        // Ordena cronologicamente entrelaçando você/outros.
        return segments.sorted { $0.startMs < $1.startMs }
    }
}
