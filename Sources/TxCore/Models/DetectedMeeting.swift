import Foundation

public struct DetectedMeeting: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let process: AudioProcess
    public let url: URL?
    public let title: String
    public let platform: Platform
    public let detectedAt: Date

    public enum Platform: String, Sendable, Hashable, Codable, CaseIterable {
        case googleMeet
        case teams
        case zoom
        case unknown
    }

    public init(
        id: UUID = UUID(),
        process: AudioProcess,
        url: URL? = nil,
        title: String,
        platform: Platform,
        detectedAt: Date = .now
    ) {
        self.id = id
        self.process = process
        self.url = url
        self.title = title
        self.platform = platform
        self.detectedAt = detectedAt
    }
}
