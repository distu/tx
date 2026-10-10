import AppKit
import TxCore

/// Controller que gerencia o ciclo de vida do HUD flutuante.
///
/// Dois modos:
/// - `alwaysVisible = true` (dock mode): HUD fica permanentemente visível
///   enquanto o app roda. Idle mostra microfone cinza clicável.
/// - `alwaysVisible = false`: HUD só aparece durante gravação / transcrição.
///
/// Usa polling leve em vez de `withObservationTracking` para evitar perda
/// de eventos em transições rápidas.
@MainActor
public final class DictationHUDController {
    private let coordinator: DictationCoordinator
    private let recordingManager: RecordingManager
    private var panel: DictationHUDPanel?
    private var loopTask: Task<Void, Never>?

    public var alwaysVisible: Bool = true

    public init(coordinator: DictationCoordinator, recordingManager: RecordingManager) {
        self.coordinator = coordinator
        self.recordingManager = recordingManager
    }

    public func start() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        loopTask?.cancel()
        panel?.orderOut(nil)
    }

    /// Força o HUD a aparecer. Em modo dock ele já está visível — esta função
    /// reposiciona no bottom center e anima um highlight.
    public func showForPreview(seconds: TimeInterval = 3) {
        ensurePanel().show()
        if !alwaysVisible {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                if case .idle = self?.coordinator.state {
                    self?.panel?.hide()
                }
            }
        }
    }

    public func setAlwaysVisible(_ value: Bool) {
        alwaysVisible = value
        if value {
            ensurePanel().show()
        } else if case .idle = coordinator.state {
            panel?.hide()
        }
    }

    private func runLoop() async {
        if alwaysVisible {
            let p = ensurePanel()
            p.resizeForState(isActive: coordinator.state.isActive, recordingCount: recordingManager.activePipelines.count, animated: false)
            p.show()
        }
        var lastActive: Bool? = nil
        var lastCount = -1
        while !Task.isCancelled {
            let active = coordinator.state.isActive
            let count = recordingManager.activePipelines.count
            if alwaysVisible {
                let p = ensurePanel()
                if !(p.isVisible) { p.show() }
                if lastActive != active || lastCount != count {
                    p.resizeForState(isActive: active, recordingCount: count, animated: true)
                    lastActive = active
                    lastCount = count
                }
            } else {
                if active {
                    let p = ensurePanel()
                    p.resizeForState(isActive: true, recordingCount: count, animated: false)
                    p.show()
                } else if count > 0 {
                    let p = ensurePanel()
                    p.resizeForState(isActive: false, recordingCount: count, animated: false)
                    if !p.isVisible { p.show() }
                } else {
                    panel?.hide()
                }
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    @discardableResult
    private func ensurePanel() -> DictationHUDPanel {
        if let panel { return panel }
        let p = DictationHUDPanel(coordinator: coordinator, recordingManager: recordingManager)
        self.panel = p
        return p
    }
}
