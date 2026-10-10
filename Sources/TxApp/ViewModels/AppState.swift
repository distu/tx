import AppKit
import AVFoundation
import Foundation
import Observation
import SwiftUI
import Darwin
import TxCore

public enum BrowserMeetingState: Equatable, Sendable {
    case unavailable
    case rooms([AppleScriptBridge.MeetTabInfo])
    case nativeTeams
}

/// Estado global do app: injeção de dependências do TxCore e roteamento entre janelas.
@Observable
@MainActor
public final class AppState {
    #if DEBUG
    public static var isScreenshotDemo: Bool {
        Bundle.main.bundleIdentifier == "dev.distuai.tx.demo"
    }
    #else
    public static let isScreenshotDemo = false
    #endif
    public let database: DatabaseManager
    public let projectRepository: ProjectRepository
    public let projectRuleRepository: ProjectRuleRepository
    public let sessionRepository: SessionRepository
    public let segmentRepository: SegmentRepository
    public let chromeProfileRepository: ChromeProfileRepository
    public let tagRepository: TagRepository

    public let processDetector: ProcessDetector
    public let meetDetector: MeetDetector
    public let chromeLauncher: ChromeProfileLauncher
    public let transcriptionEngine: TranscriptionEngine
    public let geminiTranscriptionEngine: GeminiTranscriptionEngine
    public let projectManager: ProjectManager
    public let exportManager: ExportManager
    public let recordingManager: RecordingManager
    public let intelligenceEngine: IntelligenceEngine
    public let meetBridgeServer: MeetBridgeServer
    public let dictationStore: DictationStore
    public let dictationCoordinator: DictationCoordinator
    public var hudController: DictationHUDController?

    public var showingOnboarding: Bool = false
    public var dictationInstalled: Bool = false
    public var dictationError: String?
    public var selectedSessionId: UUID?
    public var selectedProjectId: UUID?
    public var searchText: String = ""

    public var availableProcesses: [AudioProcess] = []
    public var browserMeetings: [pid_t: BrowserMeetingState] = [:]
    public var lastProcessRefresh: Date = .distantPast
    private var refreshingProcesses = false

    /// Sessão aguardando confirmação de parada após detecção de fim de reunião.
    public var meetEndedSessionId: UUID? = nil

    /// Incrementado sempre que uma sessão é classificada (título, projeto, tags).
    /// Views que listam sessões devem observar este valor para recarregar.
    public var sessionRefreshTick: Int = 0

    public init() throws {
        _ = GeminiCredentialStore.load()
        let db = try DatabaseManager(url: TxPaths.databaseURL)
        self.database = db
        self.projectRepository = ProjectRepository(database: db)
        self.projectRuleRepository = ProjectRuleRepository(database: db)
        self.sessionRepository = SessionRepository(database: db)
        self.segmentRepository = SegmentRepository(database: db)
        self.chromeProfileRepository = ChromeProfileRepository(database: db)
        self.tagRepository = TagRepository(database: db)

        self.processDetector = ProcessDetector()
        self.meetDetector = MeetDetector(processDetector: processDetector)
        self.chromeLauncher = ChromeProfileLauncher(repository: chromeProfileRepository)
        self.transcriptionEngine = TranscriptionEngine()
        self.geminiTranscriptionEngine = GeminiTranscriptionEngine()
        self.projectManager = ProjectManager(
            projectRepository: projectRepository,
            ruleRepository: projectRuleRepository
        )
        self.exportManager = ExportManager()
        self.intelligenceEngine = IntelligenceEngine()
        self.recordingManager = RecordingManager(
            database: db,
            projectManager: projectManager,
            transcriptionEngine: transcriptionEngine,
            geminiTranscriptionEngine: geminiTranscriptionEngine,
            processDetector: processDetector
        )
        self.dictationStore = DictationStore(database: db)
        self.dictationCoordinator = DictationCoordinator(
            transcription: transcriptionEngine,
            geminiTranscription: geminiTranscriptionEngine,
            store: dictationStore
        )
        let s = DictationSettings.load()
        ClipboardGuardian.shared.timings = ClipboardGuardian.Timings(
            waitAfterSetMs: s.pasteWaitAfterSetMs,
            waitBeforeRestoreMs: s.pasteWaitBeforeRestoreMs
        )
        ClipboardGuardian.shared.preserveEnabled = s.preserveClipboard

        let bridge = MeetBridgeServer()
        self.meetBridgeServer = bridge

        #if DEBUG
        if Self.isScreenshotDemo {
            try DemoFixtures.seedIfNeeded(
                projects: projectRepository,
                sessions: sessionRepository,
                segments: segmentRepository
            )
            return
        }
        #endif

        // Inicia o servidor e conecta ao RecordingManager
        bridge.start()
        let rm = self.recordingManager
        bridge.onUpdate = { meetId, title, participants in
            let meetURL = meetId.flatMap { URL(string: "https://meet.google.com/\($0)") }
            Task { @MainActor in
                rm.updateParticipants(meetingURL: meetURL, participants: participants, title: title)
            }
        }

        bridge.onMicMuteChange = { muted, meetId in
            Task { @MainActor in
                rm.setMicMute(muted, meetId: meetId)
            }
        }

        bridge.onMeetEnded = { [weak self] meetId in
            Task { @MainActor [weak self] in
                self?.handleMeetEnded(meetId: meetId)
            }
        }

        startProcessTerminationMonitoring()
        startProcessLivenessPolling()
        startDictationPermissionPolling()
    }

    /// Verifica a cada 2s se Input Monitoring foi concedido. Ao mudar de
    /// negado -> concedido, ativa o ditado automaticamente sem precisar
    /// do usuário clicar em "Ativar".
    private var dictationPermissionTimer: Timer?
    private func startDictationPermissionPolling() {
        dictationPermissionTimer?.invalidate()
        dictationPermissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.dictationInstalled && GlobalHotkeyManager.hasInputMonitoringPermission() {
                    TxLogger.app.info("Dictation: permissão detectada via polling; ativando")
                    self.startDictationIfPossible()
                }
            }
        }
    }

    /// Observa o término de processos do sistema e para automaticamente
    /// qualquer gravação cujo processo gravado tenha encerrado.
    private func startProcessTerminationMonitoring() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

            let terminatedPid = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                var sessionsToStop: [UUID] = []

                for (sessionId, pipeline) in recordingManager.activePipelines {
                    // Parada por PID ou somente pela árvore da instância encerrada.
                    if pipeline.pid == terminatedPid || pipeline.rootPID == terminatedPid {
                        sessionsToStop.append(sessionId)
                    }
                }

                for sessionId in sessionsToStop {
                    TxLogger.audio.info("Processo encerrado (pid=\(terminatedPid)): parando sessão \(sessionId.uuidString, privacy: .public)")
                    do {
                        _ = try await recordingManager.stopRecording(sessionId: sessionId)
                    } catch {
                        TxLogger.audio.error("Auto-stop failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    private var processLivenessTimer: Timer?
    private func startProcessLivenessPolling() {
        processLivenessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (sessionId, pipeline) in self.recordingManager.activePipelines {
                    let selectedGone = kill(pipeline.pid, 0) == -1 && errno == ESRCH
                    let rootGone = pipeline.rootPID.map { kill($0, 0) == -1 && errno == ESRCH } ?? false
                    if selectedGone || rootGone {
                        TxLogger.audio.warning("Capturing process ended; stopping session \(sessionId.uuidString, privacy: .public)")
                        do {
                            _ = try await self.recordingManager.stopRecording(sessionId: sessionId)
                        } catch {
                            TxLogger.audio.error("Process liveness auto-stop failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
        }
    }

    /// Identifica a sessão ativa que corresponde à reunião encerrada
    /// e sinaliza a UI para perguntar se o usuário quer parar a gravação.
    private func handleMeetEnded(meetId: String?) {
        let meetURL = meetId.flatMap { URL(string: "https://meet.google.com/\($0)") }

        // Procura sessão ativa pelo URL da reunião
        var foundId: UUID? = nil
        for sessionId in recordingManager.activePipelines.keys {
            guard let session = try? sessionRepository.find(id: sessionId) else { continue }
            if let meetURL, let sessionURL = session.meetingURL {
                if meetURL.path == sessionURL.path {
                    foundId = sessionId
                    break
                }
            }
        }

        guard let sessionId = foundId else {
            TxLogger.audio.info("handleMeetEnded: nenhuma sessão ativa encontrada para meetId=\(meetId ?? "nil", privacy: .public)")
            return
        }

        TxLogger.audio.info("handleMeetEnded: sinalizando alerta para sessão \(sessionId.uuidString, privacy: .public)")
        meetEndedSessionId = sessionId
    }

    public func refreshProcesses() async {
        guard !refreshingProcesses else { return }
        refreshingProcesses = true
        defer { refreshingProcesses = false }
        let processes = await processDetector.listAudioActiveProcesses()
        var meetings: [pid_t: BrowserMeetingState] = [:]
        for process in processes {
            meetings[process.pid] = await meetingState(for: process)
        }
        self.availableProcesses = processes
        self.browserMeetings = meetings
        self.lastProcessRefresh = .now
    }

    /// Só relaciona AppleScript a um processo quando existe uma única instância
    /// do navegador e o PID principal é o ancestral do processo com áudio.
    public func meetingState(for process: AudioProcess) async -> BrowserMeetingState? {
        let lowerName = process.name.lowercased()
        let lowerBundle = (process.bundleId ?? "").lowercased()
        // WebKit executa WebContent como XPC filho do launchd no macOS. Sem
        // vínculo demonstrável com a janela do Safari, a voz fica bloqueada.
        if lowerBundle.hasPrefix("com.apple.webkit.") || lowerName.contains("webcontent") {
            return .unavailable
        }
        if lowerName == "microsoft teams" || lowerBundle.hasPrefix("com.microsoft.teams") {
            return .nativeTeams
        }
        let isSupportedBrowser = lowerName == "arc" || lowerName == "google chrome" ||
            lowerName == "safari" || lowerBundle == "com.apple.safari" ||
            lowerBundle.hasPrefix("company.thebrowser.browser") ||
            lowerBundle == "com.google.chrome" ||
            lowerBundle.hasPrefix("com.google.chrome.helper")
        guard isSupportedBrowser else { return nil }
        guard let root = ProcessArgsReader.captureGroupRoot(
            for: process.pid, bundleId: process.bundleId
        ), let browserId = NSRunningApplication(processIdentifier: root)?.bundleIdentifier,
        ["company.thebrowser.Browser", "com.google.Chrome", "com.apple.Safari"]
            .contains(browserId) else {
            return .unavailable
        }
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: browserId)
            .filter { !$0.isTerminated }
        guard instances.count == 1, instances[0].processIdentifier == root else {
            return .unavailable
        }
        guard let tabs = await AppleScriptBridge.meetTabs(browserBundleId: browserId) else {
            return .unavailable
        }
        return .rooms(tabs)
    }

    private var lastPermissionLogAt: Date = .distantPast
    /// Inicia o pipeline de ditado global. Chamar após a app ganhar o primeiro
    /// foco — antes disso o TCC prompt de Input Monitoring pode não aparecer.
    /// Idempotente: chamar várias vezes é seguro.
    public func startDictationIfPossible() {
        if dictationInstalled { return }

        guard GlobalHotkeyManager.hasInputMonitoringPermission() else {
            // Rate-limit do log: só marca "pendente" uma vez por minuto para
            // não poluir o Debug a cada foco de janela.
            if Date().timeIntervalSince(lastPermissionLogAt) > 60 {
                DictationDebugLog.shared.warn("perm", "Input Monitoring pendente — abra Ajustes > Privacidade > Monitoramento de Entrada, ative o toggle do tx e relance o app")
                lastPermissionLogAt = Date()
            }
            dictationError = "Input Monitoring pendente. Ative em Ajustes > Privacidade e relance o app."
            return
        }
        dictationCoordinator.start()
        if dictationCoordinator.hotkey?.isInstalled == true {
            dictationInstalled = true
            dictationError = nil
            DictationDebugLog.shared.success("perm", "pipeline de ditado ativo")
        } else {
            dictationError = dictationCoordinator.lastError ?? "Tap não instalado"
        }
    }

    /// Reenvia o pedido de Input Monitoring e reinstala o tap.
    public func retryDictation() {
        dictationInstalled = false
        _ = GlobalHotkeyManager.requestInputMonitoringPermission()
        startDictationIfPossible()
    }

    /// Verifica as 3 permissões TCC e solicita APENAS as que ainda não foram
    /// concedidas. Usa as funções `hasXxx()` (sem side-effect) antes de chamar
    /// `requestXxx()` (que pode abrir prompt). Dessa forma, abertura após
    /// abertura com tudo concedido não re-exibe nenhum diálogo.
    public func requestAllDictationPermissions() {
        DictationDebugLog.shared.info("perm", "verificando permissões TCC…")

        // Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            DictationDebugLog.shared.success("perm", "Microphone: já concedida")
        case .notDetermined:
            DictationDebugLog.shared.info("perm", "Microphone: solicitando prompt")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    DictationDebugLog.shared.info("perm", "Microphone: \(granted ? "concedida" : "negada")")
                }
            }
        case .denied, .restricted:
            DictationDebugLog.shared.warn("perm", "Microphone: negada — ative em Ajustes > Privacidade > Microfone")
        @unknown default:
            break
        }

        // Input Monitoring — só dispara prompt se ainda não respondida
        if GlobalHotkeyManager.hasInputMonitoringPermission() {
            DictationDebugLog.shared.success("perm", "Input Monitoring: já concedida")
        } else {
            DictationDebugLog.shared.info("perm", "Input Monitoring: solicitando")
            _ = GlobalHotkeyManager.requestInputMonitoringPermission()
        }

        // Accessibility — idem: só chama com prompt=true se necessário
        if PasteSimulator.hasAccessibilityPermission() {
            DictationDebugLog.shared.success("perm", "Accessibility: já concedida")
        } else {
            DictationDebugLog.shared.info("perm", "Accessibility: solicitando")
            _ = PasteSimulator.requestAccessibilityPermission()
        }
    }

    /// Mostra o HUD flutuante por alguns segundos, sem depender do hotkey.
    public func testHUD() {
        hudController?.showForPreview(seconds: 3)
    }

    /// Reaplica as configurações ao pipeline em tempo real.
    public func applyDictationSettings(_ s: DictationSettings) {
        dictationCoordinator.hotkey?.updateConfig(
            GlobalHotkeyManager.Config(
                holdThresholdMs: s.holdThresholdMs,
                doubleTapWindowMs: s.doubleTapWindowMs
            )
        )
        ClipboardGuardian.shared.timings = ClipboardGuardian.Timings(
            waitAfterSetMs: s.pasteWaitAfterSetMs,
            waitBeforeRestoreMs: s.pasteWaitBeforeRestoreMs
        )
        ClipboardGuardian.shared.preserveEnabled = s.preserveClipboard
    }
}
