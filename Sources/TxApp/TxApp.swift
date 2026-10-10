import SwiftUI
import TxCore

@main
struct TxApp: App {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(InterfaceLanguage.preferenceKey) private var languagePreference = InterfaceLanguage.system.rawValue
    @State private var appState: AppState?
    @State private var initializationError: String?
    @State private var hudController: DictationHUDController?

    var body: some Scene {
        MenuBarExtra {
            if let appState {
                MenuBarContent()
                    .environment(appState)
                    .environment(\.locale, interfaceLocale)
                    .frame(width: 420, height: 520)
            } else if let initializationError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text("Falha ao iniciar tx")
                        .font(.headline)
                    Text(initializationError)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(width: 320)
            } else {
                ProgressView("Iniciando tx…")
                    .padding()
                    .frame(width: 240, height: 120)
            }
        } label: {
            Image(systemName: menuBarIconName)
                .task { initialize() }  // dispara no launch, sem esperar clique
        }
        .menuBarExtraStyle(.window)

        #if DEBUG
        Window("tx — Demo Menu", id: "demo-menu") {
            if AppState.isScreenshotDemo, let appState {
                MenuBarContent()
                    .environment(appState)
                    .environment(\.locale, interfaceLocale)
                    .frame(width: 420, height: 520)
            }
        }
        .defaultSize(width: 420, height: 520)
        #endif

        Window("tx — Biblioteca", id: "library") {
            if let appState {
                MainWindow()
                    .environment(appState)
                    .environment(\.locale, interfaceLocale)
            } else {
                Text("Carregando…")
            }
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentSize)

        Window("tx — Ditados", id: "dictation-history") {
            if let appState {
                DictationHistoryView()
                    .environment(appState)
                    .environment(\.locale, interfaceLocale)
            } else {
                Text("Carregando…")
            }
        }
        .defaultSize(width: 820, height: 620)

        Window("tx — Conserta texto", id: "text-fix") {
            TextFixView()
                .environment(\.locale, interfaceLocale)
        }
        .defaultSize(width: 640, height: 480)

        Window("tx — Dictation Debug", id: "dictation-debug") {
            if let appState {
                DictationDebugView()
                    .environment(appState)
                    .environment(\.locale, interfaceLocale)
            } else {
                Text("Carregando…")
            }
        }
        .defaultSize(width: 820, height: 600)

        Settings {
            if let appState {
                SettingsView()
                    .environment(appState)
                    .environment(\.locale, interfaceLocale)
            }
        }
    }

    private var menuBarIconName: String {
        if let appState, !appState.recordingManager.activePipelines.isEmpty {
            return "mic.circle.fill"
        }
        return "mic.circle"
    }

    private var interfaceLocale: Locale {
        let preference = InterfaceLanguage(rawValue: languagePreference) ?? .system
        return InterfaceLanguage.resolved(preference: preference).locale
    }

    private func initialize() {
        guard appState == nil else { return }
        dbg("[app] ====== tx INICIANDO ======")
        do {
            let state = try AppState()
            self.appState = state
            dbg("[app] AppState criado OK")
            if AppState.isScreenshotDemo {
                openWindow(id: "library")
                openWindow(id: "demo-menu")
                NSApplication.shared.activate(ignoringOtherApps: true)
                return
            }
            Task { await state.refreshProcesses() }

            let hud = DictationHUDController(coordinator: state.dictationCoordinator, recordingManager: state.recordingManager)
            hud.start()
            self.hudController = hud
            state.hudController = hud

            // Dispara os 3 prompts TCC logo após o app subir.
            // Se algum já foi concedido/negado antes, o macOS não reprompts
            // (limitação do TCC). Nesse caso, usar o botão "Reinstalar + Reset"
            // no Debug para limpar o cache.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                state.requestAllDictationPermissions()
                state.startDictationIfPossible()
            }

            // Retry automático quando o app volta ao foreground — o usuário pode
            // ter concedido Input Monitoring entre lançamentos.
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in state.startDictationIfPossible() }
            }

            dbg("[app] initialize() completo")
        } catch {
            dbg("[app] FALHA initialize: \(error)")
            self.initializationError = error.localizedDescription
        }
    }

}
