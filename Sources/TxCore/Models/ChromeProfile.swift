import Foundation

public struct ChromeProfile: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var name: String
    public var userDataDir: URL
    public var projectId: UUID?
    public var color: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        userDataDir: URL,
        projectId: UUID? = nil,
        color: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.userDataDir = userDataDir
        self.projectId = projectId
        self.color = color
        self.createdAt = createdAt
    }
}
