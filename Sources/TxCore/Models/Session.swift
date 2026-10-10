import Foundation

public enum SessionStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case recording
    case paused
    case recorded
    case transcribing
    case done
    case failed
}

public struct Session: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var projectId: UUID?
    public var title: String
    public var processName: String
    public var processPid: Int32?
    public var appAudioPath: URL?
    public var micAudioPath: URL?
    public var playbackAudioPath: URL?
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: Double?
    public var status: SessionStatus
    public var chromeProfileId: UUID?
    public var meetingURL: URL?
    public var transcriptModel: String?
    public var participants: [String]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID? = nil,
        title: String,
        processName: String,
        processPid: Int32? = nil,
        appAudioPath: URL? = nil,
        micAudioPath: URL? = nil,
        playbackAudioPath: URL? = nil,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        durationSeconds: Double? = nil,
        status: SessionStatus = .recording,
        chromeProfileId: UUID? = nil,
        meetingURL: URL? = nil,
        transcriptModel: String? = nil,
        participants: [String] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.processName = processName
        self.processPid = processPid
        self.appAudioPath = appAudioPath
        self.micAudioPath = micAudioPath
        self.playbackAudioPath = playbackAudioPath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.status = status
        self.chromeProfileId = chromeProfileId
        self.meetingURL = meetingURL
        self.transcriptModel = transcriptModel
        self.participants = participants
        self.createdAt = createdAt
    }
}

public struct SessionDraft: Sendable, Hashable {
    public var processName: String
    public var processBundleId: String?
    public var userDataDir: String?
    public var meetingURL: URL?
    public var title: String?

    public init(
        processName: String,
        processBundleId: String? = nil,
        userDataDir: String? = nil,
        meetingURL: URL? = nil,
        title: String? = nil
    ) {
        self.processName = processName
        self.processBundleId = processBundleId
        self.userDataDir = userDataDir
        self.meetingURL = meetingURL
        self.title = title
    }
}
