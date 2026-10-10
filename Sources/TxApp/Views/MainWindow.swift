import SwiftUI
import AVFoundation
import TxCore

struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @State private var sessions: [Session] = []
    @State private var searchHits: [SegmentSearchHit] = []
    @State private var selectedProject: Project?

    var body: some View {
        @Bindable var state = appState
        NavigationSplitView {
            sidebar
        } content: {
            sessionsList
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 500)
        } detail: {
            if let selectedId = state.selectedSessionId,
               let session = sessions.first(where: { $0.id == selectedId }) {
                SessionDetailView(session: session)
            } else {
                ContentUnavailableView(
                    "Nenhuma sessão selecionada",
                    systemImage: "waveform",
                    description: Text("Selecione uma sessão na lista ao lado.")
                )
            }
        }
        .searchable(text: $state.searchText, prompt: "Buscar no conteúdo…")
        .onAppear(perform: load)
        .onChange(of: state.searchText) { _, newValue in
            runSearch(newValue)
        }
        .onChange(of: state.selectedProjectId) { _, _ in
            load()
        }
        .onChange(of: appState.recordingManager.activePipelines.count) { _, _ in
            load()
        }
        .onChange(of: appState.recordingManager.transcribingSessionIds.count) { _, _ in
            load()
        }
        .onChange(of: appState.sessionRefreshTick) { _, _ in
            load()
        }
    }

    private var sidebar: some View {
        @Bindable var state = appState
        return List(selection: $state.selectedProjectId) {
            Section("Projetos") {
                NavigationLink(value: Optional<UUID>.none) {
                    Label("Todas as sessões", systemImage: "tray.full")
                }
                ForEach(appState.projectManager.projects) { project in
                    NavigationLink(value: Optional(project.id)) {
                        Label(project.name, systemImage: "folder.fill")
                            .foregroundStyle(Color(hex: project.color) ?? .primary)
                    }
                }
            }

            Section("Atalhos") {
                Label("Hoje", systemImage: "calendar")
                Label("Esta semana", systemImage: "calendar.badge.clock")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("tx")
    }

    private var sessionsList: some View {
        @Bindable var state = appState
        return Group {
            if !state.searchText.isEmpty {
                List(searchHits, id: \.segment.id) { hit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hit.snippet)
                            .lineLimit(3)
                        Text(InterfaceStrings.format("Segment %llds", hit.segment.startMs / 1000))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.selectedSessionId = hit.segment.sessionId
                    }
                }
            } else {
                List(sessions, id: \.id, selection: $state.selectedSessionId) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                }
            }
        }
        .navigationTitle(InterfaceStrings.text(state.searchText.isEmpty ? "Sessões" : "Resultados de busca"))
    }

    private func load() {
        do {
            if let projectId = appState.selectedProjectId {
                sessions = try appState.sessionRepository.forProject(projectId)
            } else {
                sessions = try appState.sessionRepository.all()
            }
        } catch {
            TxLogger.ui.error("MainWindow.load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runSearch(_ query: String) {
        guard !query.isEmpty else {
            searchHits = []
            return
        }
        do {
            searchHits = try appState.segmentRepository.searchFullText(query)
        } catch {
            searchHits = []
            TxLogger.ui.error("search failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(InterfaceStrings.date(session.startedAt, time: .omitted))
                        .lineLimit(1)
                    if let duration = session.durationSeconds {
                        Text(Self.formatDuration(duration))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(session.processName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.status {
        case .recording:
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .paused:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .recorded:
            Image(systemName: "waveform.circle.fill").foregroundStyle(.blue)
        case .transcribing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h\(m)min" }
        return "\(m)min"
    }
}

struct SessionDetailView: View {
    let session: Session
    @Environment(AppState.self) private var appState
    @State private var liveSession: Session
    @State private var segments: [TranscriptSegment] = []
    @State private var project: Project?
    @State private var tags: [Tag] = []
    @State private var showingIntelligence = false
    @State private var showingEdit = false
    @State private var transcribeError: String?
    @State private var audioSummary = ""
    @State private var audioWarning = false

    init(session: Session) {
        self.session = session
        _liveSession = State(initialValue: session)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                transcriptView
            }
            .padding()
        }
        .onAppear(perform: load)
        .onChange(of: session.id) { _, _ in load() }
        .onChange(of: session.status) { _, _ in load() }
        .onChange(of: appState.recordingManager.transcribingSessionIds.count) { _, _ in load() }
        .alert("Não foi possível iniciar a transcrição", isPresented: Binding(
            get: { transcribeError != nil },
            set: { if !$0 { transcribeError = nil } }
        )) {
            Button("OK") { transcribeError = nil }
        } message: {
            Text(transcribeError ?? "Erro desconhecido")
        }
        .sheet(isPresented: $showingIntelligence) {
            IntelligenceSheet(session: liveSession, segments: segments)
                .environment(appState)
        }
        .sheet(isPresented: $showingEdit) {
            EditSessionSheet(session: liveSession) {
                load()
            }
            .environment(appState)
        }
        .toolbar {
            ToolbarItemGroup {
                if liveSession.status == .recorded || liveSession.status == .failed ||
                    (liveSession.status == .done && segments.isEmpty) {
                    Button {
                        Task {
                            do {
                                try await appState.recordingManager.retryTranscription(sessionId: session.id)
                                load()
                            } catch {
                                transcribeError = error.localizedDescription
                                TxLogger.ui.error("Transcription start failed: \(error.localizedDescription, privacy: .public)")
                            }
                        }
                    } label: {
                        Label(InterfaceStrings.text(liveSession.status == .recorded ? "Transcrever agora" : "Retentar transcrição"), systemImage: "text.bubble")
                    }
                }
                Button {
                    showingEdit = true
                } label: {
                    Label("Classificar", systemImage: "tag")
                }
                Button {
                    showingIntelligence = true
                } label: {
                    Label("Inteligência", systemImage: "sparkles")
                }
                .disabled(segments.isEmpty)
                Button {
                    exportMarkdown()
                } label: {
                    Label("Markdown", systemImage: "doc.text")
                }
                .disabled(segments.isEmpty)
            }
        }
        .navigationTitle(liveSession.title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(liveSession.title).font(.title2).bold()
                Spacer()
                if let project {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(hex: project.color) ?? .accentColor)
                            .frame(width: 8, height: 8)
                        Text(project.name)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(Capsule())
                }
            }

            HStack(spacing: 12) {
                Label(InterfaceStrings.date(liveSession.startedAt), systemImage: "calendar")
                if let duration = liveSession.durationSeconds {
                    Label(formatDuration(duration), systemImage: "clock")
                }
                Label(liveSession.processName, systemImage: "app")
                if let url = liveSession.meetingURL {
                    Link(destination: url) {
                        Label("Abrir reunião", systemImage: "link")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !audioSummary.isEmpty {
                Label(InterfaceStrings.text(audioSummary), systemImage: audioWarning ? "exclamationmark.triangle" : "waveform")
                    .font(.caption)
                    .foregroundStyle(audioWarning ? .orange : .secondary)
            }

            if !liveSession.participants.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                        .foregroundStyle(.secondary)
                    Text(liveSession.participants.joined(separator: ", "))
                        .lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags) { tag in
                        TagChip(tag: tag, removable: false)
                    }
                }
            }
        }
    }

    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if segments.isEmpty {
                ContentUnavailableView(
                    InterfaceStrings.text(liveSession.status == .done ? "Nenhuma fala detectada" : "Sem transcrição ainda"),
                    systemImage: "waveform",
                    description: Text(InterfaceStrings.text(liveSession.status == .transcribing ? "Transcrevendo…" :
                        liveSession.status == .recorded ? "Áudio salvo. Clique em Transcrever agora na barra de ferramentas." :
                        liveSession.status == .done ? "O áudio foi analisado, mas não houve fala com sinal suficiente." : "Nenhum segmento."))
                )
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ForEach(segments) { segment in
                    SegmentRow(segment: segment)
                }
            }
        }
    }

    private func load() {
        do {
            // Re-busca a sessão do banco para pegar título/projeto atualizados
            if let fresh = try? appState.sessionRepository.find(id: session.id) {
                liveSession = fresh
            }
            segments = try appState.segmentRepository.forSession(session.id)
            project = liveSession.projectId.flatMap { try? appState.projectRepository.find(id: $0) }
            tags = (try? appState.tagRepository.tagsForSession(session.id)) ?? []
            let appSeconds = audioDuration(liveSession.appAudioPath)
            let micSeconds = audioDuration(liveSession.micAudioPath)
            if liveSession.endedAt != nil {
                audioSummary = InterfaceStrings.format("App: %@ · Mic: %@", appSeconds.map(formatDuration) ?? InterfaceStrings.text("ausente"), micSeconds.map(formatDuration) ?? InterfaceStrings.text("ausente"))
                let expected = liveSession.durationSeconds ?? 0
                audioWarning = expected > 30 && (appSeconds ?? 0) < expected * 0.5 ||
                    expected > 30 && (micSeconds ?? 0) < expected * 0.5
                if audioWarning { audioSummary += InterfaceStrings.text(" · Canal curto ou pausas na gravação") }
            }
        } catch {
            TxLogger.ui.error("Detail load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func exportMarkdown() {
        let sessionCopy = session
        let projectCopy = project
        let segmentsCopy = segments
        Task {
            let markdown = await appState.exportManager.exportMarkdown(
                session: sessionCopy,
                project: projectCopy,
                segments: segmentsCopy
            )
            await savePanel(initialName: "\(sessionCopy.title).md", content: markdown)
        }
    }

    @MainActor
    private func savePanel(initialName: String, content: String) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = initialName
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func audioDuration(_ url: URL?) -> TimeInterval? {
        guard let url, let file = try? AVAudioFile(forReading: url),
              file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(speakerLabel)
                    .font(.caption.bold())
                    .foregroundStyle(segment.speaker == .you ? Color.green : Color.blue)
                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private var timestamp: String {
        let total = segment.startMs / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private var speakerLabel: String {
        InterfaceStrings.text(segment.speaker == .you ? "Você" : "Outros")
    }
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#") else { return nil }
        let raw = String(hex.dropFirst())
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
