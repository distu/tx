import SwiftUI
import TxCore
import CoreAudio

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("Geral", systemImage: "gear") }
            AudioSettingsTab()
                .tabItem { Label("Áudio", systemImage: "mic") }
            PermissionsSettingsTab()
                .tabItem { Label("Permissões", systemImage: "lock.shield") }
            ModelsSettingsTab()
                .tabItem { Label("Modelos", systemImage: "cpu") }
            IntelligenceSettingsTab()
                .tabItem { Label("Inteligência", systemImage: "sparkles") }
            ProjectsSettingsTab()
                .tabItem { Label("Projetos", systemImage: "folder") }
            LogsSettingsTab()
                .tabItem { Label("Logs", systemImage: "terminal") }
        }
        .frame(width: 720, height: 560)
    }
}

struct GeneralSettingsTab: View {
    @AppStorage("tx.launchAtLogin") private var launchAtLogin = false
    @AppStorage("tx.showRecordingPill") private var showRecordingPill = true

    var body: some View {
        Form {
            Toggle("Iniciar com o sistema", isOn: $launchAtLogin)
            Toggle("Mostrar pílula flutuante durante gravação", isOn: $showRecordingPill)
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct PermissionsSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var micPermission: String = "verificando…"
    @State private var accessibility: Bool = false

    var body: some View {
        Form {
            Section("Permissões necessárias") {
                HStack {
                    Label("Microfone", systemImage: "mic")
                    Spacer()
                    Text(micPermission).foregroundStyle(.secondary)
                }
                HStack {
                    Label("Acessibilidade", systemImage: "accessibility")
                    Spacer()
                    Text(accessibility ? "concedida" : "não concedida")
                        .foregroundStyle(accessibility ? .green : .orange)
                    Button("Abrir Ajustes") {
                        openAccessibilitySettings()
                    }
                }
                HStack {
                    Label("Captura de áudio de processos", systemImage: "waveform")
                    Spacer()
                    Text("requerida (Core Audio)").foregroundStyle(.secondary)
                }
            }
            Section("Automação") {
                Text("O tx consulta o Chrome via AppleScript para detectar URLs de reunião. Autorize no primeiro prompt que aparecer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: refresh)
    }

    private func refresh() {
        accessibility = AXWindowReader.isAccessibilityEnabled()
        micPermission = "ver Ajustes > Privacidade"
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ModelsSettingsTab: View {
    @Environment(AppState.self) private var appState
    @AppStorage("tx.transcription.model") private var storedModel: String = WhisperModel.default.rawValue
    @State private var selected: WhisperModel = .default
    @State private var isLoading = false
    @State private var status: String = ""

    var body: some View {
        Form {
            Picker("Modelo Whisper", selection: $selected) {
                ForEach(WhisperModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .onChange(of: selected) { _, newValue in
                storedModel = newValue.rawValue
            }
            HStack {
                Button {
                    load()
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Baixar / validar modelo")
                    }
                }
                .disabled(isLoading)
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            if let resolved = WhisperModel(rawValue: storedModel) {
                selected = resolved
            }
        }
    }

    private func load() {
        isLoading = true
        status = "baixando…"
        let engine = appState.transcriptionEngine
        let model = selected
        storedModel = model.rawValue
        Task {
            do {
                try await engine.loadModel(model)
                await engine.unloadModel()
                await MainActor.run {
                    status = "em cache; carregamento sob demanda"
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    status = "falhou: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
}

struct ProjectsSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var newProjectName: String = ""
    @State private var newProjectColor: String = ProjectColorPalette.defaultHex

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(appState.projectManager.projects) { project in
                    HStack {
                        Circle()
                            .fill(Color(hex: project.color) ?? .gray)
                            .frame(width: 12, height: 12)
                        Text(project.name)
                        Spacer()
                        Button(role: .destructive) {
                            try? appState.projectManager.deleteProject(project)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Paleta").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(ProjectColorPalette.swatches, id: \.self) { hex in
                        swatch(hex: hex)
                    }
                }
            }

            HStack {
                TextField("Nome do projeto", text: $newProjectName)
                TextField("#RRGGBB", text: $newProjectColor)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                Circle()
                    .fill(Color(hex: newProjectColor) ?? .gray)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                Button("Criar") {
                    guard !newProjectName.isEmpty else { return }
                    _ = try? appState.projectManager.createProject(
                        name: newProjectName,
                        color: newProjectColor
                    )
                    newProjectName = ""
                }
            }
        }
        .padding()
    }

    private func swatch(hex: String) -> some View {
        let isSelected = hex.caseInsensitiveCompare(newProjectColor) == .orderedSame
        return Button {
            newProjectColor = hex
        } label: {
            Circle()
                .fill(Color(hex: hex) ?? .gray)
                .frame(width: 22, height: 22)
                .overlay(
                    Circle()
                        .stroke(isSelected ? Color.white : Color.white.opacity(0.15),
                                lineWidth: isSelected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .help(hex)
    }
}

enum ProjectColorPalette {
    static let swatches: [String] = [
        "#4A90E2", // azul
        "#50C878", // verde
        "#F5A623", // laranja
        "#E94B3C", // vermelho
        "#9B59B6", // roxo
        "#F06292", // rosa
        "#1ABC9C", // turquesa
        "#F1C40F", // amarelo
        "#34495E", // grafite
        "#E67E22", // abóbora
        "#16A085", // teal
        "#8E44AD"  // violeta
    ]

    static var defaultHex: String { swatches[0] }
}

struct IntelligenceSettingsTab: View {
    @AppStorage("tx.intelligence.provider") private var intelligenceProvider: String = "codex"
    @State private var apiKey: String = ""
    @AppStorage(GeminiModel.intelligenceModelKey) private var intelligenceModelRaw: String = GeminiModel.intelligenceDefault.rawValue
    @AppStorage(GeminiModel.transcriptionModelKey) private var transcriptionModelRaw: String = GeminiModel.transcriptionDefault.rawValue
    @AppStorage(GeminiModel.useGeminiTranscriptionKey) private var useGeminiTranscription: Bool = false
    @State private var isRevealed = false
    @State private var testStatus: String = ""
    @State private var isTesting = false
    @State private var codexConnected = false
    @State private var codexBusy = false
    @State private var codexStatus = "Verificando Codex…"

    private var intelligenceModel: GeminiModel {
        get { GeminiModel(rawValue: intelligenceModelRaw) ?? .intelligenceDefault }
    }
    private var transcriptionModel: GeminiModel {
        get { GeminiModel(rawValue: transcriptionModelRaw) ?? .transcriptionDefault }
    }

    var body: some View {
        Form {
            Section("Assinatura ChatGPT / Codex") {
                Picker("Gerar atas e briefings com", selection: $intelligenceProvider) {
                    Text("Codex (assinatura ChatGPT)").tag("codex")
                    Text("Gemini API").tag("gemini")
                }
                HStack {
                    Button(codexConnected ? "Verificar conexão" : "Conectar com ChatGPT") {
                        Task { await connectCodex() }
                    }
                    .disabled(codexBusy)
                    if codexBusy { ProgressView().controlSize(.small) }
                    Text(codexStatus)
                        .font(.caption)
                        .foregroundStyle(codexConnected ? .green : .secondary)
                }
                Text("Usa o login oficial do Codex CLI neste Mac e a assinatura para analisar transcrições. A conexão não aceita áudio; gravações continuam no transcritor configurado.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Link("Gerenciar uso da assinatura", destination: URL(string: "https://chatgpt.com/#settings/Usage")!)
                    .font(.caption)
            }
            Section("Gemini API") {
                HStack {
                    if isRevealed {
                        TextField("Gemini API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Gemini API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Button("Salvar chave") {
                        testStatus = GeminiCredentialStore.save(apiKey)
                            ? "Salva no Keychain"
                            : "Não foi possível salvar no Keychain"
                    }
                    Button {
                        testKey()
                    } label: {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Testar chave")
                        }
                    }
                    .disabled(apiKey.isEmpty || isTesting)

                    Text(testStatus)
                        .font(.caption)
                        .foregroundStyle(testStatus.contains("OK") || testStatus.contains("Salva") ? .green : .red)
                }

                Link("Obter chave gratuita em Google AI Studio",
                     destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.caption)
            }

            Section("Modelo Gemini para resumos / atas / briefings") {
                Picker("Modelo", selection: $intelligenceModelRaw) {
                    ForEach(GeminiModel.allCases) { m in
                        Text(m.displayName).tag(m.rawValue)
                    }
                }
                .disabled(intelligenceProvider != "gemini")
                if intelligenceProvider == "gemini" {
                    Text(intelligenceModel.costHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Codex usa gpt-6.1-sol nesta versão.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Transcrição via Gemini API") {
                Toggle("Usar Gemini para transcrever (em vez do Whisper local)", isOn: $useGeminiTranscription)
                if useGeminiTranscription {
                    Picker("Modelo de transcrição", selection: $transcriptionModelRaw) {
                        ForEach(GeminiModel.allCases) { m in
                            Text(m.displayName).tag(m.rawValue)
                        }
                    }
                    Text(transcriptionModel.costHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Áudio enviado para Google. Limite inline 18MB. Acima disso, Whisper local é usado como fallback.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text("Whisper local (offline). Requer modelo carregado em \"Modelos\".")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sobre os artefatos") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Ata", systemImage: "doc.text.fill")
                        .font(.subheadline.bold())
                    Text("Transcrição analítica completa, organizada por tópicos. Nenhuma informação é perdida.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("Briefing", systemImage: "list.bullet.clipboard.fill")
                        .font(.subheadline.bold())
                    Text("Resumo executivo com decisões tomadas e lista de ações (action items).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            apiKey = GeminiCredentialStore.load()
            await refreshCodexStatus()
        }
    }

    private func refreshCodexStatus() async {
        codexConnected = await CodexCLIIntelligence.shared.isLoggedIn()
        codexStatus = codexConnected ? "Conectado pelo Codex CLI" : "Codex CLI sem login"
    }

    private func connectCodex() async {
        codexBusy = true
        defer { codexBusy = false }
        if await CodexCLIIntelligence.shared.isLoggedIn() {
            intelligenceProvider = "codex"
            await refreshCodexStatus()
            return
        }
        codexStatus = "Aguardando login no navegador…"
        do {
            try await CodexCLIIntelligence.shared.login()
            intelligenceProvider = "codex"
            await refreshCodexStatus()
        } catch {
            codexConnected = false
            codexStatus = error.localizedDescription
        }
    }

    private func testKey() {
        isTesting = true
        testStatus = ""
        let key = apiKey
        Task {
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "contents": [["parts": [["text": "ping"]]]]
            ])
            req.timeoutInterval = 15
            let status: String
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                status = code == 200 ? "OK - chave válida" : "Erro HTTP \(code)"
            } catch {
                status = error.localizedDescription
            }
            await MainActor.run {
                testStatus = status
                isTesting = false
            }
        }
    }
}

struct AudioSettingsTab: View {
    @AppStorage("tx.audio.micDeviceID") private var selectedDeviceID: Int = 0
    @State private var availableDevices: [(id: Int, name: String)] = []
    @State private var currentDefaultID: Int = 0

    var body: some View {
        Form {
            Section("Microfone") {
                Picker("Dispositivo de entrada", selection: $selectedDeviceID) {
                    Text("Padrão do sistema").tag(0)
                    Divider()
                    ForEach(availableDevices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .pickerStyle(.automatic)
                .onChange(of: selectedDeviceID) { _, newValue in
                    applySelection(newValue)
                }

                if currentDefaultID > 0, let name = nameFor(id: currentDefaultID) {
                    LabeledContent("Default do sistema agora", value: name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Ao selecionar um dispositivo, o tx altera o input default do macOS (mesmo efeito de Ajustes > Som > Entrada). Todos os apps vão usar esse mic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            loadDevices()
            refreshCurrent()
        }
    }

    private func loadDevices() {
        availableDevices = AudioDeviceManager.listInputDevices().map {
            (id: Int($0.id), name: $0.name)
        }
    }

    private func refreshCurrent() {
        if let id = AudioDeviceManager.currentDefaultInputDevice() {
            currentDefaultID = Int(id)
        }
    }

    private func nameFor(id: Int) -> String? {
        availableDevices.first { $0.id == id }?.name
    }

    private func applySelection(_ newValue: Int) {
        guard newValue > 0 else { return }
        _ = AudioDeviceManager.setDefaultInputDevice(AudioDeviceID(newValue))
        refreshCurrent()
    }
}

struct LogsSettingsTab: View {
    @State private var content: String = ""
    @State private var filter: String = ""
    @State private var timer: Timer?
    @State private var autoScroll: Bool = true

    private let logPath = "/tmp/tx-debug.log"
    private let maxLines = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Filtrar (ex: mic, rec, error)", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button("Atualizar") { reload() }
                Button("Limpar arquivo") { clearFile() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(filteredContent())
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .id("logBottom")
                }
                .background(Color.black.opacity(0.3))
                .onChange(of: content) { _, _ in
                    if autoScroll {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
            Text("Arquivo: \(logPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            reload()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in reload() }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func filteredContent() -> String {
        let lines = content.components(separatedBy: "\n")
        let tail = lines.suffix(maxLines)
        if filter.isEmpty {
            return tail.joined(separator: "\n")
        }
        let f = filter.lowercased()
        return tail.filter { $0.lowercased().contains(f) }.joined(separator: "\n")
    }

    private func reload() {
        guard let data = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            content = "(sem logs em \(logPath))"
            return
        }
        content = data
    }

    private func clearFile() {
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        reload()
    }
}
