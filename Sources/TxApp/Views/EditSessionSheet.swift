import SwiftUI
import TxCore

// MARK: - Cores predefinidas para projetos e tags

private let presetColors: [(name: String, hex: String)] = [
    ("Azul",    "#3B82F6"),
    ("Verde",   "#10B981"),
    ("Roxo",    "#8B5CF6"),
    ("Rosa",    "#EC4899"),
    ("Laranja", "#F59E0B"),
    ("Vermelho","#EF4444"),
    ("Teal",    "#14B8A6"),
    ("Índigo",  "#6366F1"),
    ("Cinza",   "#6B7280"),
]

// MARK: - EditSessionSheet

struct EditSessionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let session: Session
    var onSave: (() -> Void)?

    // Campos editáveis
    @State private var title: String
    @State private var selectedProjectId: UUID?
    @State private var selectedTags: [Tag] = []

    // Dados carregados
    @State private var allProjects: [Project] = []
    @State private var allTags: [Tag] = []

    // Criação inline de projeto
    @State private var showingCreateProject = false
    @State private var newProjectName = ""
    @State private var newProjectColor = "#3B82F6"

    // Criação inline de tag
    @State private var showingCreateTag = false
    @State private var newTagName = ""
    @State private var newTagColor = "#8B5CF6"

    @State private var isSaving = false

    init(session: Session, onSave: (() -> Void)? = nil) {
        self.session = session
        self.onSave = onSave
        _title = State(initialValue: session.title)
        _selectedProjectId = State(initialValue: session.projectId)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    titleSection
                    projectSection
                    tagsSection
                }
                .padding()
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 560)
        .onAppear(perform: load)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Classificar sessão")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    // MARK: - Título

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Título", systemImage: "pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Título da sessão", text: $title)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Projeto

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Projeto", systemImage: "folder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Menu {
                Button {
                    selectedProjectId = nil
                } label: {
                    Label("Nenhum projeto", systemImage: "minus")
                }
                Divider()
                ForEach(allProjects) { project in
                    Button {
                        selectedProjectId = project.id
                    } label: {
                        HStack {
                            Circle()
                                .fill(Color(hex: project.color) ?? .gray)
                                .frame(width: 10, height: 10)
                            Text(project.name)
                        }
                    }
                }
                Divider()
                Button {
                    withAnimation { showingCreateProject = true }
                } label: {
                    Label("Criar projeto…", systemImage: "plus")
                }
            } label: {
                HStack {
                    if let pid = selectedProjectId,
                       let project = allProjects.first(where: { $0.id == pid }) {
                        Circle()
                            .fill(Color(hex: project.color) ?? .gray)
                            .frame(width: 10, height: 10)
                        Text(project.name)
                    } else {
                        Text("Nenhum projeto")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)

            if showingCreateProject {
                createProjectRow
            }
        }
    }

    private var createProjectRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Nome do projeto", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                Button("Criar") {
                    createProject()
                }
                .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancelar") {
                    withAnimation {
                        showingCreateProject = false
                        newProjectName = ""
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            colorPicker(selected: $newProjectColor)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tags", systemImage: "tag")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Chips das tags selecionadas
            if !selectedTags.isEmpty {
                tagChipsFlow(tags: selectedTags, removable: true)
            }

            // Botão para adicionar tag
            Menu {
                let remaining = allTags.filter { tag in
                    !selectedTags.contains(where: { $0.id == tag.id })
                }
                if remaining.isEmpty && !showingCreateTag {
                    Text("Nenhuma tag disponível")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remaining) { tag in
                        Button {
                            selectedTags.append(tag)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color(hex: tag.color) ?? .purple)
                                    .frame(width: 10, height: 10)
                                Text(tag.name)
                            }
                        }
                    }
                    if !remaining.isEmpty { Divider() }
                }
                Button {
                    withAnimation { showingCreateTag = true }
                } label: {
                    Label("Nova tag…", systemImage: "plus")
                }
            } label: {
                Label("Adicionar tag", systemImage: "plus")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)

            if showingCreateTag {
                createTagRow
            }
        }
    }

    @ViewBuilder
    private func tagChipsFlow(tags: [Tag], removable: Bool) -> some View {
        // Layout em grade adaptativa (quebra linha automaticamente)
        let columns = [GridItem(.adaptive(minimum: 80, maximum: 200), spacing: 6)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(tags) { tag in
                TagChip(tag: tag, removable: removable) {
                    selectedTags.removeAll { $0.id == tag.id }
                }
            }
        }
    }

    private var createTagRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Nome da tag", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                Button("Criar") {
                    createTag()
                }
                .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancelar") {
                    withAnimation {
                        showingCreateTag = false
                        newTagName = ""
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            colorPicker(selected: $newTagColor)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Color picker inline

    private func colorPicker(selected: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text("Cor:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(presetColors, id: \.hex) { preset in
                Button {
                    selected.wrappedValue = preset.hex
                } label: {
                    Circle()
                        .fill(Color(hex: preset.hex) ?? .gray)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: selected.wrappedValue == preset.hex ? 2 : 0)
                        )
                        .overlay(
                            Circle()
                                .stroke(Color(hex: preset.hex)?.opacity(0.5) ?? .clear, lineWidth: selected.wrappedValue == preset.hex ? 3 : 0)
                                .scaleEffect(1.3)
                        )
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancelar") {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])

            Button("Salvar") {
                save()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Ações

    private func load() {
        allProjects = (try? appState.projectRepository.all()) ?? []
        allTags = (try? appState.tagRepository.all()) ?? []
        selectedTags = (try? appState.tagRepository.tagsForSession(session.id)) ?? []
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let project = Project(name: name, color: newProjectColor)
        do {
            try appState.projectRepository.insert(project)
            appState.projectManager.reload()
            allProjects = (try? appState.projectRepository.all()) ?? []
            selectedProjectId = project.id
            withAnimation {
                showingCreateProject = false
                newProjectName = ""
                newProjectColor = "#3B82F6"
            }
        } catch {
            TxLogger.ui.error("Erro ao criar projeto: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let tag = Tag(name: name, color: newTagColor)
        do {
            try appState.tagRepository.insert(tag)
            allTags = (try? appState.tagRepository.all()) ?? []
            selectedTags.append(tag)
            withAnimation {
                showingCreateTag = false
                newTagName = ""
                newTagColor = "#8B5CF6"
            }
        } catch {
            TxLogger.ui.error("Erro ao criar tag: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        isSaving = true
        do {
            guard var updated = try appState.sessionRepository.find(id: session.id) else {
                isSaving = false
                return
            }
            updated.title = title.trimmingCharacters(in: .whitespaces)
            updated.projectId = selectedProjectId
            try appState.sessionRepository.update(updated)
            try appState.tagRepository.setTags(for: session.id, tagIds: selectedTags.map(\.id))
            // Sinaliza para a MainWindow e outros observers que sessões foram modificadas
            appState.sessionRefreshTick += 1
            onSave?()
            dismiss()
        } catch {
            TxLogger.ui.error("Erro ao salvar classificação: \(error.localizedDescription, privacy: .public)")
        }
        isSaving = false
    }
}

// MARK: - TagChip

struct TagChip: View {
    let tag: Tag
    let removable: Bool
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hex: tag.color) ?? .purple)
                .frame(width: 8, height: 8)
            Text(tag.name)
                .font(.caption)
                .lineLimit(1)
            if removable {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (Color(hex: tag.color) ?? .purple).opacity(0.15)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke((Color(hex: tag.color) ?? .purple).opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
