import AppKit
import SwiftUI
import TxCore

/// NSPanel flutuante bottom-center que exibe o HUD de ditado.
///
/// - `styleMask`: `.nonactivatingPanel` para não roubar foco; `.fullSizeContentView`
///   para estender o SwiftUI até as bordas do vidro do painel.
/// - `level = .statusBar`: acima de `.floating`, abaixo de menu extras críticos.
/// - `collectionBehavior`: `.canJoinAllSpaces` + `.stationary` + `.fullScreenAuxiliary`
///   garante visibilidade em Spaces e em apps full-screen.
@MainActor
public final class DictationHUDPanel: NSPanel {

    public init(coordinator: DictationCoordinator, recordingManager: RecordingManager) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .statusBar
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        self.isMovableByWindowBackground = false
        self.animationBehavior = .utilityWindow
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: DictationHUDView(coordinator: coordinator, recordingManager: recordingManager))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.contentView = hosting

        positionAtBottomCenter()
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public func show() {
        positionAtBottomCenter()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            self.animator().alphaValue = 1
        }
    }

    public func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.orderOut(nil)
            }
        })
    }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        // Cola totalmente na borda absoluta da tela. Se o Dock estiver
        // visível, assenta logo acima dele; se auto-hide, borda pura.
        let full = screen.frame
        let visible = screen.visibleFrame
        let size = self.frame.size
        let dockPadding = max(0, visible.minY - full.minY)
        let y = full.minY + dockPadding

        let origin = NSPoint(
            x: full.midX - size.width / 2,
            y: y
        )
        self.setFrameOrigin(origin)
    }

    /// Reposiciona + redimensiona quando o estado alterna entre colapsado
    /// (só ícone) e expandido (waveform + controles).
    public func resizeForState(isActive: Bool, recordingCount: Int, animated: Bool = true) {
        let newSize = NSSize(
            width: recordingCount > 0 ? 330 : (isActive ? 240 : 160),
            height: 40 + CGFloat(recordingCount) * 38
        )

        guard let screen = NSScreen.main else { return }
        let full = screen.frame
        let visible = screen.visibleFrame
        let dockPadding = max(0, visible.minY - full.minY)
        let y = full.minY + dockPadding
        let origin = NSPoint(x: full.midX - newSize.width / 2, y: y)
        let newFrame = NSRect(origin: origin, size: newSize)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(newFrame, display: true)
            }
        } else {
            self.setFrame(newFrame, display: true)
        }
    }
}

// MARK: - HUDView (SwiftUI)

struct DictationHUDView: View {
    let coordinator: DictationCoordinator
    let recordingManager: RecordingManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage(InterfaceLanguage.preferenceKey) private var languagePreference = InterfaceLanguage.system.rawValue
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            if !recordingManager.activePipelines.isEmpty {
                ForEach(recordingManager.activePipelines.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                    if let pipeline = recordingManager.activePipelines[id] {
                        RecordingHealthRow(pipeline: pipeline, now: now)
                    }
                }
            }
            HStack {
                if coordinator.state.isActive { expandedLayout } else { collapsedLayout }
            }
            .frame(maxWidth: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.black.opacity(coordinator.state.isActive ? 0.92 : 0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                )
        )
        .task {
            while !Task.isCancelled {
                now = .now
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .environment(\.locale, InterfaceLanguage.resolved(preference: InterfaceLanguage(rawValue: languagePreference) ?? .system).locale)
    }

    /// Idle: acesso rápido à biblioteca, ditados e captura de voz.
    private var collapsedLayout: some View {
        HStack(spacing: 0) {
            Button(action: openTextFix) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 36, height: 40)
            }
            .buttonStyle(.borderless)
            .help(InterfaceStrings.text("Conserta texto colado (junta linhas hard-wrap do terminal)"))

            divider

            Button(action: openLibrary) {
                Image(systemName: "recordingtape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.borderless)
            .help(InterfaceStrings.text("Abrir gravações e transcrever áudio salvo"))

            divider

            Button(action: openDashboard) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 36, height: 40)
            }
            .buttonStyle(.borderless)
            .help(InterfaceStrings.text("Abrir histórico de ditados"))

            divider

            Button(action: { coordinator.startManual() }) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.borderless)
            .help(InterfaceStrings.text("Clique para começar a ditar (ou segure Fn)"))
        }
        .frame(width: 160, height: 40)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 18)
    }

    private func openDashboard() {
        openWindow(id: "dictation-history")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openLibrary() {
        openWindow(id: "library")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openTextFix() {
        openWindow(id: "text-fix")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Ativo: pill expandida (240x40) com waveform + status + X cancelar.
    private var expandedLayout: some View {
        HStack(spacing: 10) {
            Image(systemName: iconNameActive)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tintColor)
                .frame(width: 20)

            WaveformStrip(levels: coordinator.waveformLevels, tint: tintColor)
                .frame(width: 130, height: 20)

            statusBadge

            if case .error = coordinator.state,
               coordinator.lastFailedDictationId != nil,
               !coordinator.isRetrying {
                Button {
                    Task { await coordinator.retryLastFailed() }
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help(InterfaceStrings.text("Reprocessar último áudio"))
            }

            Button(action: { coordinator.cancelFromHUD() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.borderless)
            .help(InterfaceStrings.text("Cancelar (ESC)"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 240, height: 40)
    }

    private var iconNameActive: String {
        switch coordinator.state {
        case .recording(let mode, _): return mode == .locked ? "lock.fill" : "mic.fill"
        case .transcribing: return "waveform"
        case .pasting: return "text.cursor"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "waveform"
        }
    }

    /// Níveis mostrados no waveform: durante gravação, segue os RMS reais;
    /// em idle, deixa uma respiração suave pra indicar "vivo".
    private var levels: [Float] {
        if case .recording = coordinator.state {
            return coordinator.waveformLevels
        }
        return Array(repeating: 0.05, count: coordinator.waveformLevels.count)
    }

    @ViewBuilder
    private var appBadge: some View {
        Image(systemName: "waveform.circle.fill")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(.white.opacity(0.9))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch coordinator.state {
        case .idle:
            EmptyView()
        case .recording(let mode, _):
            if mode == .locked {
                Button(action: { coordinator.stopLocked() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.borderless)
                .help(InterfaceStrings.text("Parar gravação travada"))
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
            }
        case .transcribing:
            ProgressView()
                .scaleEffect(0.5)
                .tint(.white)
        case .pasting:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
        }
    }

    private var tintColor: Color {
        switch coordinator.state {
        case .recording(let mode, _): return mode == .locked ? .yellow : .green
        case .transcribing, .pasting: return .blue
        case .error: return .orange
        case .idle: return .white.opacity(0.3)
        }
    }
}

private struct RecordingHealthRow: View {
    let pipeline: AudioPipeline
    let now: Date

    private var appHealth: String {
        if pipeline.appWriteError != nil { return "Erro ao gravar app" }
        guard let last = pipeline.appLastBufferAt else {
            return now.timeIntervalSince(pipeline.startedAt) > 8 ? "Sem buffers do app" : "Aguardando app"
        }
        if now.timeIntervalSince(last) > 8 { return "Sem buffers do app" }
        if let audible = pipeline.appLastAudibleAt, now.timeIntervalSince(audible) < 8 { return "Capturando" }
        return "App em silêncio"
    }

    private var micHealth: String {
        if pipeline.micWriteError != nil { return "Erro ao gravar mic" }
        switch pipeline.micGateStatus {
        case .awaitingMeet: return "Aguardando estado da chamada"
        case .staleMeet: return "Estado da chamada indisponível; mic pausado"
        case .unassociatedMeet: return "Chamada não identificada; mic pausado"
        case .mutedByMeet: return "Mic mutado na chamada"
        case .notMeeting, .liveByMeet: break
        }
        guard let last = pipeline.micLastBufferAt else {
            return now.timeIntervalSince(pipeline.startedAt) > 8 ? "Sem buffers do mic" : "Aguardando mic"
        }
        if now.timeIntervalSince(last) > 8 { return "Sem buffers do mic" }
        if let audible = pipeline.micLastAudibleAt, now.timeIntervalSince(audible) < 8 { return "Capturando" }
        return "Mic em silêncio"
    }

    var body: some View {
        HStack(spacing: 7) {
            if let app = NSRunningApplication(processIdentifier: pipeline.rootPID ?? pipeline.pid),
               let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 17, height: 17)
            } else {
                Image(systemName: "app.fill").frame(width: 17)
            }
            Text(NSRunningApplication(processIdentifier: pipeline.rootPID ?? pipeline.pid)?.localizedName ?? pipeline.processName)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
            VStack(spacing: 3) {
                AudioLevelBar(level: now.timeIntervalSince(pipeline.appLastBufferAt ?? .distantPast) > 2 ? -160 : pipeline.appAudioLevel, tint: .blue)
                AudioLevelBar(level: now.timeIntervalSince(pipeline.micLastBufferAt ?? .distantPast) > 2 ? -160 : pipeline.micAudioLevel, tint: .green)
            }
            .frame(width: 62, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(InterfaceStrings.text(appHealth)).foregroundStyle(appHealth == "Capturando" ? .blue : .orange)
                Text(InterfaceStrings.text(micHealth)).foregroundStyle(micHealth == "Capturando" ? .green : .orange)
            }
            .font(.system(size: 8))
            .lineLimit(1)
            Spacer(minLength: 0)
            Circle().fill(pipeline.state == .paused ? .orange : .red).frame(width: 6, height: 6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(height: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5) }
        .help(InterfaceStrings.format("App: %@, %lld frames; mic: %@, %lld frames", InterfaceStrings.text(appHealth), pipeline.appWrittenFrames, InterfaceStrings.text(micHealth), pipeline.micWrittenFrames))
    }
}

private struct WaveformStrip: View {
    let levels: [Float]
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            let count = levels.count
            guard count > 0 else { return }
            let barWidth = size.width / CGFloat(count)
            let midY = size.height / 2
            let gap: CGFloat = 1.5

            for (i, raw) in levels.enumerated() {
                let normalized = CGFloat(max(0, min(1, raw)))
                let h = max(2, normalized * size.height)
                let x = CGFloat(i) * barWidth
                let rect = CGRect(
                    x: x,
                    y: midY - h / 2,
                    width: max(1, barWidth - gap),
                    height: h
                )
                ctx.fill(
                    Path(roundedRect: rect, cornerRadius: 1.5),
                    with: .color(tint.opacity(0.9))
                )
            }
        }
    }
}
