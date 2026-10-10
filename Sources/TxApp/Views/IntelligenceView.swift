import SwiftUI
import TxCore

struct IntelligenceSheet: View {
    let session: Session
    let segments: [TranscriptSegment]

    @Environment(AppState.self) private var appState
    @AppStorage("tx.intelligence.provider") private var intelligenceProvider: String = "codex"
    @State private var apiKey: String = ""
    @AppStorage(GeminiModel.intelligenceModelKey) private var intelligenceModelRaw: String = GeminiModel.intelligenceDefault.rawValue

    @State private var mode: IntelligenceMode = .ata
    @State private var artifact: IntelligenceArtifact?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var codexConnected = false

    var body: some View {
        VStack(spacing: 0) {
            // Cabeçalho
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inteligência")
                        .font(.headline)
                    Text(session.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Seletor de modo
            VStack(alignment: .leading, spacing: 8) {
                Text("Tipo de artefato").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(IntelligenceMode.allCases) { m in
                        ModeCard(mode: m, isSelected: mode == m)
                            .onTapGesture { mode = m }
                    }
                }
            }
            .padding()

            // Chave de API
            if intelligenceProvider == "gemini" && apiKey.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Chave Gemini não configurada")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Configurar") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            if intelligenceProvider == "codex" && !codexConnected {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Conecte o Codex em Configurações > Inteligência")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Configurar") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            // Botão gerar
            Button {
                generate()
            } label: {
                if isGenerating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(InterfaceStrings.format("Generating %@…", InterfaceStrings.text(mode.displayName)))
                    }
                } else {
                    Label(InterfaceStrings.format("Generate %@", InterfaceStrings.text(mode.displayName)), systemImage: mode.systemImage)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isGenerating || segments.isEmpty || (intelligenceProvider == "gemini" ? apiKey.isEmpty : !codexConnected))
            .padding(.horizontal)
            .padding(.bottom, 12)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            Divider()

            // Resultado
            if let artifact {
                ArtifactResultView(artifact: artifact, session: session)
            } else if !isGenerating {
                ContentUnavailableView(
                    "Nenhum artefato gerado",
                    systemImage: "sparkles",
                    description: Text("Escolha o tipo e clique em Gerar.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(InterfaceStrings.format("Analyzing transcript with %@…", intelligenceProvider == "codex" ? "Codex" : "Gemini"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 640, height: 700)
        .task {
            apiKey = GeminiCredentialStore.load()
            codexConnected = await CodexCLIIntelligence.shared.isLoggedIn()
        }
    }

    private func generate() {
        isGenerating = true
        errorMessage = nil
        artifact = nil

        let engine = appState.intelligenceEngine
        let sessionCopy = session
        let segmentsCopy = segments
        let modeCopy = mode
        let key = apiKey
        let model = GeminiModel(rawValue: intelligenceModelRaw) ?? .intelligenceDefault
        let provider = intelligenceProvider

        Task {
            do {
                let result: IntelligenceArtifact
                if provider == "codex" {
                    let prompt = try await engine.makePrompt(
                        mode: modeCopy, session: sessionCopy, segments: segmentsCopy
                    )
                    result = try await CodexCLIIntelligence.shared.generate(
                        prompt: prompt, sessionId: sessionCopy.id, mode: modeCopy
                    )
                } else {
                    result = try await engine.generate(
                        mode: modeCopy,
                        session: sessionCopy,
                        segments: segmentsCopy,
                        apiKey: key,
                        model: model
                    )
                }
                await MainActor.run {
                    artifact = result
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isGenerating = false
                }
            }
        }
    }
}

// MARK: - ModeCard

private struct ModeCard: View {
    let mode: IntelligenceMode
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(InterfaceStrings.text(mode.displayName), systemImage: mode.systemImage)
                .font(.subheadline.bold())
            Text(InterfaceStrings.text(mode.description))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.blue.opacity(0.6) : Color.clear, lineWidth: 1.5)
        )
    }
}

// MARK: - ArtifactResultView

private struct ArtifactResultView: View {
    let artifact: IntelligenceArtifact
    let session: Session

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar do resultado
            HStack {
                Image(systemName: artifact.mode.systemImage)
                    .foregroundStyle(.blue)
                Text(InterfaceStrings.text(artifact.mode.displayName))
                    .font(.subheadline.bold())
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(artifact.generatedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(artifact.content, forType: .string)
                } label: {
                    Label("Copiar", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button {
                    exportMarkdown()
                } label: {
                    Label("Exportar", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.03))

            Divider()

            ScrollView {
                Text(artifact.content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.title) — \(artifact.mode.displayName).md"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? artifact.content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
