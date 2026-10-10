import SwiftUI
import AppKit
import TxCore

/// Janela flutuante borderless que mostra o estado de gravações ativas.
/// Arrastável, transparente, fica sempre no topo.
@MainActor
final class RecordingPillWindowController: NSWindowController {
    private let appState: AppState
    private static var controllers: [RecordingPillWindowController] = []

    init(appState: AppState) {
        self.appState = appState
        let window = BorderlessFloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 60),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(
            rootView: RecordingPillView()
                .environment(appState)
        )
        super.init(window: window)
        Self.controllers.append(self)
        showCentered()
    }

    required init?(coder: NSCoder) { nil }

    private func showCentered() {
        guard let window, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - window.frame.width / 2
        let y = frame.maxY - window.frame.height - 40
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.orderFrontRegardless()
    }

    static func dismissAll() {
        for controller in controllers {
            controller.close()
        }
        controllers.removeAll()
    }
}

private final class BorderlessFloatingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct RecordingPillView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(radius: 8)

            if let (sessionId, pipeline) = firstActive {
                HStack(spacing: 10) {
                    pulsingDot
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gravando")
                            .font(.caption.bold())
                        Text("PID \(pipeline.pid)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 2) {
                        AudioLevelBar(level: pipeline.appAudioLevel, tint: .blue)
                            .frame(width: 20, height: 12)
                        AudioLevelBar(level: pipeline.micAudioLevel, tint: .green)
                            .frame(width: 20, height: 12)
                    }
                    Button {
                        Task {
                            _ = try? await appState.recordingManager.stopRecording(sessionId: sessionId)
                        }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
            } else {
                Text("Nenhuma sessão")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 260, height: 60)
    }

    private var firstActive: (UUID, AudioPipeline)? {
        guard let first = appState.recordingManager.activePipelines.first else { return nil }
        return (first.key, first.value)
    }

    private var pulsingDot: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(Color.red.opacity(0.4), lineWidth: 2)
                    .scaleEffect(1.8)
            )
    }
}
