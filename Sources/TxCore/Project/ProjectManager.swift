import Foundation
import Observation

@Observable
@MainActor
public final class ProjectManager {
    public private(set) var projects: [Project] = []
    public private(set) var rules: [ProjectRule] = []

    private let projectRepository: ProjectRepository
    private let ruleRepository: ProjectRuleRepository

    public init(projectRepository: ProjectRepository, ruleRepository: ProjectRuleRepository) {
        self.projectRepository = projectRepository
        self.ruleRepository = ruleRepository
        reload()
    }

    public func reload() {
        do {
            projects = try projectRepository.all()
            rules = try ruleRepository.allOrderedByPriority()
        } catch {
            TxLogger.database.error("ProjectManager reload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func createProject(name: String, color: String) throws -> Project {
        let project = Project(name: name, color: color)
        try projectRepository.insert(project)
        reload()
        return project
    }

    public func deleteProject(_ project: Project) throws {
        try projectRepository.delete(id: project.id)
        reload()
    }

    public func addRule(_ rule: ProjectRule) throws {
        try ruleRepository.insert(rule)
        reload()
    }

    public func removeRule(_ rule: ProjectRule) throws {
        try ruleRepository.delete(id: rule.id)
        reload()
    }

    /// Infere qual projeto atribuir a uma sessão com base nas regras ordenadas por prioridade.
    public func inferProject(for draft: SessionDraft) -> Project? {
        for rule in rules {
            if matches(rule: rule, draft: draft) {
                return projects.first { $0.id == rule.projectId }
            }
        }
        return nil
    }

    private func matches(rule: ProjectRule, draft: SessionDraft) -> Bool {
        switch rule.type {
        case .chromeProfile:
            return draft.userDataDir == rule.value
        case .processName:
            return draft.processName.localizedCaseInsensitiveContains(rule.value)
        case .urlPattern:
            guard let url = draft.meetingURL?.absoluteString else { return false }
            return url.localizedCaseInsensitiveContains(rule.value)
        case .emailDomain:
            // MVP1 não tem contexto de email; regra será usada em V2 quando houver extensão.
            return false
        }
    }
}
