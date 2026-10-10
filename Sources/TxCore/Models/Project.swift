import Foundation

public struct Project: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var name: String
    public var color: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        color: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.createdAt = createdAt
    }
}

public struct ProjectRule: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let projectId: UUID
    public let type: RuleType
    public let value: String
    public let priority: Int

    public enum RuleType: String, Sendable, Hashable, Codable, CaseIterable {
        case chromeProfile
        case emailDomain
        case processName
        case urlPattern
    }

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        type: RuleType,
        value: String,
        priority: Int = 0
    ) {
        self.id = id
        self.projectId = projectId
        self.type = type
        self.value = value
        self.priority = priority
    }
}
