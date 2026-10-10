import Foundation

public struct TranscriptSegment: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let sessionId: UUID
    public let speaker: Speaker
    public let channel: Channel
    public let text: String
    public let startMs: Int
    public let endMs: Int
    public let confidence: Float?

    public enum Speaker: String, Sendable, Hashable, Codable, CaseIterable {
        case you
        case others
    }

    public enum Channel: String, Sendable, Hashable, Codable, CaseIterable {
        case app
        case mic
    }

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        speaker: Speaker,
        channel: Channel,
        text: String,
        startMs: Int,
        endMs: Int,
        confidence: Float? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.speaker = speaker
        self.channel = channel
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
    }
}
