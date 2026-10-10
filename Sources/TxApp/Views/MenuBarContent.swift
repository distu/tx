import SwiftUI
import TxCore

struct MenuBarContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettingsEnv
    @State private var refreshTimer: Timer?
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dictationSection
                    activeRecordingsSection
                    availableProcessesSection
                }
                .padding()
            }
            Divider()
            footer
        }
        .alert("Reunião encerrada", isPresented: Binding(
            get: { state.meetEndedSessionId != nil },
            set: { if !$0 { state.meetEndedSessionId = nil } }
        )) {
            Button("Parar gravação") {
                if let sessionId = state.meetEndedSessionId {
                    state.meetEndedSessionId = nil
                    Task {
                        do {
                            _ = try await appState.recordingManager.stopRecording(sessionId: sessionId)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .keyboardShortcut(.return, modifiers: [])

            Button("Continuar gravando", role: .cancel) {
                state.meetEndedSessionId = nil
            }
        } message: {
            Text("A reunião terminou. Deseja parar a gravação agora?")
        }
        .onAppear {
            if AppState.isScreenshotDemo { return }
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                Task { await appState.refreshProcesses() }
            }
            Task { await appState.refreshProcesses() }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform")
                .font(.title3)
            Text("tx")
                .font(.headline)
            Spacer()
            Button {
                if AppState.isScreenshotDemo { return }
                Task { await appState.refreshProcesses() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(InterfaceStrings.text("Atualizar lista de processos"))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var dictationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ditado por voz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                dictationStatusBadge
            }

            if let err = appState.dictationError {
                Text(InterfaceStrings.text(err))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    appState.retryDictation()
                } label: {
                    Label("Ativar", systemImage: "power")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    appState.testHUD()
                } label: {
                    Label("Testar HUD", systemImage: "rectangle.inset.filled")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
                    if let url { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Permissão", systemImage: "lock.shield")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    openWindow(id: "dictation-debug")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Debug", systemImage: "ladybug")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Segure Fn para ditar · Fn duplo trava · ESC cancela")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var dictationStatusBadge: some View {
        Group {
            if appState.dictationInstalled {
                Label("Pronto", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Inativo", systemImage: "xmark.circle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2)
    }

    private var activeRecordingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gravando agora")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.recordingManager.activePipelines.isEmpty {
                Text("Nenhuma sessão ativa")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(appState.recordingManager.activePipelines.keys), id: \.self) { sessionId in
                    if let pipeline = appState.recordingManager.activePipelines[sessionId] {
                        ActiveRecordingRow(sessionId: sessionId, pipeline: pipeline)
                    }
                }
            }
        }
    }

    private var availableProcessesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Apps com áudio ativo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if appState.availableProcesses.isEmpty {
                    Text("nenhum")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(appState.availableProcesses) { process in
                let meetingState = appState.browserMeetings[process.pid]
                ProcessRow(process: process, meetingState: meetingState) {
                    await startRecording(process: process, displayedMeetingState: meetingState)
                }
            }

            if let errorMessage {
                    Text(InterfaceStrings.text(errorMessage))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Biblioteca") {
                openWindow(id: "library")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderless)

            Button("Ditados") {
                openWindow(id: "dictation-history")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderless)

            Spacer()

            Menu {
                Button("Configurações…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettingsEnv()
                }
                Button("Sobre tx") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Divider()
                Button("Sair") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func startRecording(
        process: AudioProcess,
        displayedMeetingState: BrowserMeetingState?
    ) async {
        do {
            let currentMeetingState = await appState.meetingState(for: process)
            guard currentMeetingState == displayedMeetingState else {
                await appState.refreshProcesses()
                errorMessage = "As abas da reunião mudaram. Confira a lista atualizada antes de gravar."
                return
            }
            let meeting: AppleScriptBridge.MeetTabInfo?
            if case .rooms(let rooms) = currentMeetingState, rooms.count == 1 {
                meeting = rooms[0]
            } else {
                meeting = nil
            }
            let meetingTitle = meeting.map { ProcessRow.displayTitle(for: $0) }
            let fallbackTitle = currentMeetingState == .nativeTeams
                ? "Microsoft Teams — \(Self.timeFormatter.string(from: .now))"
                : "\(process.name) — \(Self.timeFormatter.string(from: .now))"
            _ = try await appState.recordingManager.startRecording(
                process: process,
                title: meetingTitle ?? fallbackTitle,
                meetingURL: meeting?.url,
                protectMeetingMic: currentMeetingState != nil
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            TxLogger.ui.error("startRecording failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

struct ProcessRow: View {
    let process: AudioProcess
    let meetingState: BrowserMeetingState?
    let onStart: () async -> Void
    @State private var isStarting = false

    var body: some View {
        HStack(spacing: 10) {
            ProcessIconView(iconData: process.iconData)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(.callout)
                    .lineLimit(1)
                if let meetingState {
                    meetingDetails(meetingState)
                } else if let bundleId = process.bundleId {
                    Text(bundleId)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                isStarting = true
                Task {
                    await onStart()
                    isStarting = false
                }
            } label: {
                if isStarting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                }
            }
            .buttonStyle(.borderless)
            .disabled(isStarting)
            .help(InterfaceStrings.format("Record all audio from %@", process.name))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func meetingDetails(_ state: BrowserMeetingState) -> some View {
        switch state {
        case .rooms(let rooms) where rooms.count == 1:
            Text(Self.displayTitle(for: rooms[0]))
                .font(.caption)
                .lineLimit(2)
            Text(rooms[0].isTeams
                 ? InterfaceStrings.format("Teams · all audio from %@", process.name)
                 : InterfaceStrings.format("Meet %@ · all audio from %@", rooms[0].roomCode, process.name))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .rooms(let rooms) where rooms.count > 1:
            ForEach(rooms.indices, id: \.self) { index in
                Text("\(rooms[index].isTeams ? "Teams" : "Meet \(rooms[index].roomCode)"): \(Self.displayTitle(for: rooms[index]))")
                    .font(.caption2)
                    .lineLimit(1)
            }
            Text(InterfaceStrings.format("%d meeting tabs · recording mixes all audio from %@. Use separate browsers or instances.", rooms.count, process.name))
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .rooms:
            Text("Título da reunião não identificado")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(InterfaceStrings.format("No Meet or Teams room found · recording covers all of %@", process.name))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .unavailable:
            Text("Título da reunião não identificado")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(InterfaceStrings.format("Meeting match unconfirmed · all audio from %@. Use separate browsers or instances.", process.name))
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .nativeTeams:
            Text("Teams · áudio do aplicativo")
                .font(.caption)
            Text("O mic só abre com o botão da chamada detectado")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    static func displayTitle(for tab: AppleScriptBridge.MeetTabInfo) -> String {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if tab.isTeams { return title.isEmpty ? "Microsoft Teams" : title }
        return title.isEmpty || title == "Google Meet" ? "Meet \(tab.roomCode)" : title
    }
}

struct ProcessIconView: View {
    let iconData: Data?

    var body: some View {
        if let iconData, let image = NSImage(data: iconData) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }
}

struct ActiveRecordingRow: View {
    let sessionId: UUID
    let pipeline: AudioPipeline
    @Environment(AppState.self) private var appState
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var stopError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(pipeline.state == .paused ? Color.orange : Color.red)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PID \(pipeline.pid)")
                        .font(.callout)
                    Text(Self.formatElapsed(elapsed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()

                Button {
                    Task {
                        if pipeline.state == .paused {
                            await appState.recordingManager.resumeRecording(sessionId: sessionId)
                        } else {
                            await appState.recordingManager.pauseRecording(sessionId: sessionId)
                        }
                    }
                } label: {
                    Image(systemName: pipeline.state == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)

                Button {
                    Task {
                        do {
                            _ = try await appState.recordingManager.stopRecording(sessionId: sessionId)
                        } catch {
                            stopError = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }

            LiveWaveformView(pipeline: pipeline)
                .frame(height: 44)
            if let stopError {
                Text(stopError).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    private func startTimer() {
        timer?.invalidate()
        elapsed = Date().timeIntervalSince(pipeline.startedAt)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [startedAt = pipeline.startedAt] _ in
            Task { @MainActor in
                elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

struct AudioLevelBar: View {
    let level: Float
    let tint: Color

    private var normalized: CGFloat {
        let clamped = max(-60, min(0, Double(level)))
        return CGFloat((clamped + 60) / 60)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint.opacity(0.15))
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: geo.size.width * normalized)
            }
        }
    }
}

/// Desenha um waveform rolante com o histórico de níveis do pipeline.
/// Dois canais sobrepostos: app (azul) no topo, mic (verde) na base.
struct LiveWaveformView: View {
    let pipeline: AudioPipeline
    @State private var appSamples: [Float] = Array(repeating: -60, count: Self.sampleCount)
    @State private var micSamples: [Float] = Array(repeating: -60, count: Self.sampleCount)
    @State private var sampleTimer: Timer?

    private static let sampleCount = 80
    private static let sampleInterval: TimeInterval = 1.0 / 30.0

    var body: some View {
        Canvas { context, size in
            draw(
                samples: appSamples,
                color: Color.blue,
                size: size,
                mirrored: false,
                in: &context
            )
            draw(
                samples: micSamples,
                color: Color.green,
                size: size,
                mirrored: true,
                in: &context
            )

            let midY = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: 0, y: midY))
            line.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(line, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
        .onAppear { startSampling() }
        .onDisappear { stopSampling() }
    }

    private func draw(
        samples: [Float],
        color: Color,
        size: CGSize,
        mirrored: Bool,
        in context: inout GraphicsContext
    ) {
        guard !samples.isEmpty else { return }
        let barWidth = size.width / CGFloat(samples.count)
        let gap: CGFloat = 1
        let halfHeight = size.height / 2
        let midY = halfHeight

        for (index, level) in samples.enumerated() {
            let clamped = max(-60, min(0, Double(level)))
            let normalized = CGFloat((clamped + 60) / 60)
            let barHeight = max(1, halfHeight * normalized)
            let x = CGFloat(index) * barWidth
            let y = mirrored ? midY : midY - barHeight
            let rect = CGRect(x: x, y: y, width: max(1, barWidth - gap), height: barHeight)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 1),
                with: .color(color.opacity(0.85))
            )
        }
    }

    private func startSampling() {
        stopSampling()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { _ in
            Task { @MainActor in
                appSamples.removeFirst()
                appSamples.append(pipeline.appAudioLevel)
                micSamples.removeFirst()
                micSamples.append(pipeline.micAudioLevel)
            }
        }
    }

    private func stopSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
    }
}
