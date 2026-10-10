import Foundation

/// Tag colorida que pode ser associada a uma ou mais sessões.
public struct Tag: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var color: String  // hex: #RRGGBB
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, color: String = "#8B5CF6", createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.color = color
        self.createdAt = createdAt
    }
}
