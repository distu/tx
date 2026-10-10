import Foundation
import AVFoundation
import Observation

public enum PipelineState: String, Sendable {
    case idle
    case starting
    case running
    case paused
    case stopping
    case stopped
    case failed
}

public enum MicGateStatus: Sendable, Equatable {
    case notMeeting
    case awaitingMeet
    case staleMeet
    case unassociatedMeet
    case mutedByMeet
    case liveByMeet
}

/// Orquestra a captura dual (tap de processo + microfone) de uma única sessão.
/// Grava três arquivos m4a:
///  - `app.m4a` — canal do app a 16 kHz mono (entrada do Whisper)
///  - `mic.m4a` — canal do mic a 16 kHz mono (entrada do Whisper)
///  - `playback.m4a` — canal do app a 44.1 kHz stereo (qualidade de reprodução)
@Observable
@MainActor
public final class AudioPipeline {
    public let pid: pid_t
    public let rootPID: pid_t?
    public let bundleId: String?
    public let processName: String
    public let sessionId: UUID
    public let sessionDirectory: URL
    public let startedAt: Date

    public private(set) var state: PipelineState = .idle
    public private(set) var appAudioLevel: Float = -160
    public private(set) var micAudioLevel: Float = -160
    public private(set) var appLastBufferAt: Date?
    public private(set) var micLastBufferAt: Date?
    public private(set) var appLastAudibleAt: Date?
    public private(set) var micLastAudibleAt: Date?
    public private(set) var appWrittenFrames: Int64 = 0
    public private(set) var micWrittenFrames: Int64 = 0
    public private(set) var appWriteError: String?
    public private(set) var micWriteError: String?
    public private(set) var isMicMuted = false
    public private(set) var micGateStatus: MicGateStatus = .notMeeting
    private var lastMeetMicStateAt: Date?
    private let meetMicStateTimeout: TimeInterval = 6

    // Criado lazily em start() após descoberta dos PIDs relacionados.
    private var processTap: ProcessTap?
    private let microphoneTap: MicrophoneTap

    private var appTranscriptWriter: AudioFileWriter?
    private var micTranscriptWriter: AudioFileWriter?
    private var playbackWriter: AudioFileWriter?

    private var appStreamTask: Task<Void, Never>?
    private var micStreamTask: Task<Void, Never>?

    private var pausedFlag = false

    public init(
        pid: pid_t,
        bundleId: String? = nil,
        processName: String? = nil,
        sessionId: UUID = UUID(),
        startedAt: Date = .now,
        micDeviceID: AudioDeviceID? = nil
    ) {
        self.pid = pid
        self.rootPID = ProcessArgsReader.captureGroupRoot(for: pid, bundleId: bundleId)
        self.bundleId = bundleId
        self.processName = processName ?? bundleId ?? "PID \(pid)"
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.sessionDirectory = TxPaths.sessionDirectory(sessionId: sessionId, startedAt: startedAt)
        self.microphoneTap = MicrophoneTap(preferredDeviceID: micDeviceID)
    }

    public func start() async throws {
        guard state == .idle else {
            throw TxError.invalidState("AudioPipeline already started (state=\(state.rawValue))")
        }
        state = .starting
        dbg("[pipeline] START pid=\(pid) bundleId=\(bundleId ?? "nil") session=\(sessionId)")

        do {
            dbg("[pipeline] criando writers...")
            appTranscriptWriter = try AudioFileWriter(
                url: sessionDirectory.appendingPathComponent("app.m4a"),
                targetSampleRate: 16_000,
                channels: 1
            )
            micTranscriptWriter = try AudioFileWriter(
                url: sessionDirectory.appendingPathComponent("mic.m4a"),
                targetSampleRate: 16_000,
                channels: 1
            )
            playbackWriter = try AudioFileWriter(
                url: sessionDirectory.appendingPathComponent("playback.m4a"),
                targetSampleRate: 44_100,
                channels: 2
            )
            dbg("[pipeline] writers OK")

            // Descobre todos os PIDs de áudio relacionados antes de criar o tap.
            let tapPids = discoverTapPids()
            dbg("[pipeline] tapPids=\(tapPids)")

            let tap = ProcessTap(pids: tapPids)
            self.processTap = tap
            dbg("[pipeline] chamando tap.start()...")
            try tap.start()
            dbg("[pipeline] tap.start() OK")

            dbg("[pipeline] chamando microphoneTap.start()...")
            try microphoneTap.start()
            dbg("[pipeline] microphoneTap.start() OK")

            startConsumingStreams()
            state = .running
            dbg("[pipeline] RUNNING session=\(sessionId)")
        } catch {
            state = .failed
            dbg("[pipeline] FALHA: \(error)")
            cleanup()
            throw error
        }
    }

    /// Inclui somente os processos de áudio descendentes da mesma instância.
    /// A árvore de processos é o limite de isolamento entre instâncias Chromium.
    private func discoverTapPids() -> [pid_t] {
        var result: [pid_t] = [pid]

        // Dump TODOS os processos CoreAudio para diagnóstico
        if let allObjects = try? CoreAudioBridge.listProcessObjects() {
            dbg("[discover] === TODOS processos CoreAudio (\(allObjects.count) total) ===")
            for obj in allObjects {
                let p = (try? CoreAudioBridge.pid(for: obj)) ?? 0
                let out = CoreAudioBridge.isRunningOutput(processObject: obj)
                let inp = CoreAudioBridge.isRunningInput(processObject: obj)
                let running = CoreAudioBridge.isRunning(processObject: obj)
                let bid = CoreAudioBridge.bundleID(for: obj) ?? "<nil>"
                dbg("[discover]   obj=\(obj) PID=\(p) output=\(out) input=\(inp) running=\(running) bundle=\(bid)")
            }
            dbg("[discover] =============================================")
        } else {
            dbg("[discover] FALHA listProcessObjects()")
        }

        guard let root = rootPID,
              let allObjects = try? CoreAudioBridge.listProcessObjects() else { return result }

        for obj in allObjects {
            guard let p = try? CoreAudioBridge.pid(for: obj),
                  p > 0,
                  ProcessArgsReader.isDescendant(p, of: root),
                  !result.contains(p) else { continue }
            guard CoreAudioBridge.isRunningOutput(processObject: obj) else { continue }
            result.append(p)
            dbg("[discover] +PID \(p) da instância \(root)")
        }

        dbg("[discover] resultado final: \(result)")
        return result
    }

    public func pause() async {
        guard state == .running else { return }
        pausedFlag = true
        state = .paused
    }

    public func resume() async {
        guard state == .paused else { return }
        pausedFlag = false
        state = .running
    }

    /// Começa sem gravar voz até que o estado local do Meet seja confirmado.
    /// Uma sessão sem URL inequívoca permanece protegida.
    public func protectMicUntilMeetState(hasAssociation: Bool) {
        micGateStatus = hasAssociation ? .awaitingMeet : .unassociatedMeet
        lastMeetMicStateAt = nil
        isMicMuted = true
        microphoneTap.pauseCapture()
    }

    /// Pausa ou retoma a captura do microfone com base no estado confirmado do Meet.
    /// Não afeta a captura de áudio do app (processTap).
    public func setMicMute(_ muted: Bool) {
        lastMeetMicStateAt = .now
        let nextStatus: MicGateStatus = muted ? .mutedByMeet : .liveByMeet
        if micGateStatus == nextStatus { return }
        micGateStatus = nextStatus
        isMicMuted = muted
        if muted {
            microphoneTap.pauseCapture()
        } else {
            microphoneTap.resumeCapture()
        }
    }

    public func setMeetMicStateUnknown() {
        guard micGateStatus != .staleMeet else { return }
        micGateStatus = .staleMeet
        isMicMuted = true
        microphoneTap.pauseCapture()
    }

    func expireMeetMicStateIfNeeded(now: Date = .now) {
        guard micGateStatus == .liveByMeet,
              let lastMeetMicStateAt,
              now.timeIntervalSince(lastMeetMicStateAt) > meetMicStateTimeout else { return }
        micGateStatus = .staleMeet
        isMicMuted = true
        microphoneTap.pauseCapture()
        TxLogger.audio.warning("Meet mic state expired; microphone capture gated")
    }

    public func stop() async -> AudioFiles? {
        guard state == .running || state == .paused else { return nil }
        state = .stopping

        try? processTap?.stop()
        microphoneTap.stop()

        // Os streams terminam após o tap; drena os buffers já enfileirados
        // antes de fechar os arquivos AAC.
        await appStreamTask?.value
        await micStreamTask?.value
        appStreamTask = nil
        micStreamTask = nil

        appTranscriptWriter?.close()
        micTranscriptWriter?.close()
        playbackWriter?.close()

        state = .stopped

        return AudioFiles(
            transcriptAudio: sessionDirectory.appendingPathComponent("app.m4a"),
            playbackAudio: sessionDirectory.appendingPathComponent("playback.m4a"),
            appChannel: sessionDirectory.appendingPathComponent("app.m4a"),
            micChannel: sessionDirectory.appendingPathComponent("mic.m4a")
        )
    }

    // MARK: - Private

    private var appBufferCount = 0
    private var micBufferCount = 0

    private func startConsumingStreams() {
        guard let appStream = processTap?.stream else {
            dbg("[streams] ERRO: processTap?.stream é nil!")
            return
        }
        let micStream = microphoneTap.stream
        dbg("[streams] iniciando consumo de streams")

        appStreamTask = Task.detached { [weak self] in
            for await box in appStream {
                guard let self else { return }
                await self.handleAppBuffer(box)
            }
            dbg("[streams] appStream ENCERROU")
        }

        micStreamTask = Task.detached { [weak self] in
            for await box in micStream {
                guard let self else { return }
                await self.handleMicBuffer(box)
            }
            dbg("[streams] micStream ENCERROU")
        }
    }

    private func handleAppBuffer(_ box: AudioBufferBox) {
        guard !pausedFlag else { return }
        appBufferCount += 1
        let buffer = box.buffer
        let db = AudioLevelMeter.rmsLevel(buffer: buffer)
        appLastBufferAt = .now
        if db > -55 { appLastAudibleAt = .now }
        if appBufferCount <= 5 || appBufferCount % 200 == 0 {
            dbg("[app-buf] #\(appBufferCount) frames=\(buffer.frameLength) dB=\(db)")
        }
        self.appAudioLevel = db
        do {
            try appTranscriptWriter?.write(buffer)
            try playbackWriter?.write(buffer)
            appWrittenFrames += Int64(buffer.frameLength)
        } catch {
            appWriteError = error.localizedDescription
            TxLogger.audio.error("App buffer write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleMicBuffer(_ box: AudioBufferBox) {
        guard !pausedFlag else { return }
        expireMeetMicStateIfNeeded()
        if isMicMuted && !box.wasMutedAtCapture {
            box.silenceInPlace()
        }
        micBufferCount += 1
        let buffer = box.buffer
        let db = AudioLevelMeter.rmsLevel(buffer: buffer)
        micLastBufferAt = .now
        if db > -55 { micLastAudibleAt = .now }
        if micBufferCount <= 5 || micBufferCount % 200 == 0 {
            dbg("[mic-buf] #\(micBufferCount) frames=\(buffer.frameLength) dB=\(db)")
        }
        self.micAudioLevel = db
        do {
            try micTranscriptWriter?.write(buffer)
            micWrittenFrames += Int64(buffer.frameLength)
        } catch {
            micWriteError = error.localizedDescription
            TxLogger.audio.error("Mic buffer write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cleanup() {
        appStreamTask?.cancel()
        micStreamTask?.cancel()
        try? processTap?.stop()
        microphoneTap.stop()
        appTranscriptWriter?.close()
        micTranscriptWriter?.close()
        playbackWriter?.close()
    }
}
