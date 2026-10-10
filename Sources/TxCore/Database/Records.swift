import Foundation
import GRDB

// MARK: - Project

struct ProjectRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "projects"

    var id: String
    var name: String
    var color: String
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
        case createdAt = "created_at"
    }

    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let color = Column("color")
        static let createdAt = Column("created_at")
    }

    init(from project: Project) {
        self.id = project.id.uuidString
        self.name = project.name
        self.color = project.color
        self.createdAt = project.createdAt.timeIntervalSince1970
    }

    func toDomain() -> Project {
        Project(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            color: color,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}

// MARK: - ProjectRule

struct ProjectRuleRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "project_rules"

    var id: String
    var projectId: String
    var type: String
    var value: String
    var priority: Int

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case type
        case value
        case priority
    }

    init(from rule: ProjectRule) {
        self.id = rule.id.uuidString
        self.projectId = rule.projectId.uuidString
        self.type = rule.type.rawValue
        self.value = rule.value
        self.priority = rule.priority
    }

    func toDomain() -> ProjectRule? {
        guard
            let uuid = UUID(uuidString: id),
            let projectUuid = UUID(uuidString: projectId),
            let ruleType = ProjectRule.RuleType(rawValue: type)
        else { return nil }
        return ProjectRule(
            id: uuid,
            projectId: projectUuid,
            type: ruleType,
            value: value,
            priority: priority
        )
    }
}

// MARK: - ChromeProfile

struct ChromeProfileRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "chrome_profiles"

    var id: String
    var name: String
    var userDataDir: String
    var projectId: String?
    var color: String?
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case userDataDir = "user_data_dir"
        case projectId = "project_id"
        case color
        case createdAt = "created_at"
    }

    init(from profile: ChromeProfile) {
        self.id = profile.id.uuidString
        self.name = profile.name
        self.userDataDir = profile.userDataDir.path
        self.projectId = profile.projectId?.uuidString
        self.color = profile.color
        self.createdAt = profile.createdAt.timeIntervalSince1970
    }

    func toDomain() -> ChromeProfile {
        ChromeProfile(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            userDataDir: URL(fileURLWithPath: userDataDir),
            projectId: projectId.flatMap { UUID(uuidString: $0) },
            color: color,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}

// MARK: - Session

struct SessionRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "sessions"

    var id: String
    var projectId: String?
    var title: String
    var processName: String
    var processPid: Int32?
    var appAudioPath: String?
    var micAudioPath: String?
    var playbackAudioPath: String?
    var startedAt: Double
    var endedAt: Double?
    var durationSeconds: Double?
    var status: String
    var chromeProfileId: String?
    var meetingUrl: String?
    var transcriptModel: String?
    var participants: String  // JSON array: ["Alice","Bob"]
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case title
        case processName = "process_name"
        case processPid = "process_pid"
        case appAudioPath = "app_audio_path"
        case micAudioPath = "mic_audio_path"
        case playbackAudioPath = "playback_audio_path"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case status
        case chromeProfileId = "chrome_profile_id"
        case meetingUrl = "meeting_url"
        case transcriptModel = "transcript_model"
        case participants
        case createdAt = "created_at"
    }

    init(from session: Session) {
        self.id = session.id.uuidString
        self.projectId = session.projectId?.uuidString
        self.title = session.title
        self.processName = session.processName
        self.processPid = session.processPid
        self.appAudioPath = session.appAudioPath?.path
        self.micAudioPath = session.micAudioPath?.path
        self.playbackAudioPath = session.playbackAudioPath?.path
        self.startedAt = session.startedAt.timeIntervalSince1970
        self.endedAt = session.endedAt?.timeIntervalSince1970
        self.durationSeconds = session.durationSeconds
        self.status = session.status.rawValue
        self.chromeProfileId = session.chromeProfileId?.uuidString
        self.meetingUrl = session.meetingURL?.absoluteString
        self.transcriptModel = session.transcriptModel
        self.participants = (try? String(
            data: JSONEncoder().encode(session.participants), encoding: .utf8
        )) ?? "[]"
        self.createdAt = session.createdAt.timeIntervalSince1970
    }

    func toDomain() -> Session {
        let decodedParticipants: [String] = (try? JSONDecoder().decode(
            [String].self,
            from: Data(participants.utf8)
        )) ?? []
        return Session(
            id: UUID(uuidString: id) ?? UUID(),
            projectId: projectId.flatMap { UUID(uuidString: $0) },
            title: title,
            processName: processName,
            processPid: processPid,
            appAudioPath: appAudioPath.map { URL(fileURLWithPath: $0) },
            micAudioPath: micAudioPath.map { URL(fileURLWithPath: $0) },
            playbackAudioPath: playbackAudioPath.map { URL(fileURLWithPath: $0) },
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: endedAt.map { Date(timeIntervalSince1970: $0) },
            durationSeconds: durationSeconds,
            status: SessionStatus(rawValue: status) ?? .failed,
            chromeProfileId: chromeProfileId.flatMap { UUID(uuidString: $0) },
            meetingURL: meetingUrl.flatMap { URL(string: $0) },
            transcriptModel: transcriptModel,
            participants: decodedParticipants,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}

// MARK: - Tag

struct TagRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "tags"

    var id: String
    var name: String
    var color: String
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
        case createdAt = "created_at"
    }

    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let createdAt = Column("created_at")
    }

    init(from tag: Tag) {
        self.id = tag.id.uuidString
        self.name = tag.name
        self.color = tag.color
        self.createdAt = tag.createdAt.timeIntervalSince1970
    }

    func toDomain() -> Tag {
        Tag(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            color: color,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}

// MARK: - SessionTag

struct SessionTagRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "session_tags"

    var sessionId: String
    var tagId: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case tagId = "tag_id"
    }
}

// MARK: - Segment

struct SegmentRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "segments"

    var id: String
    var sessionId: String
    var speaker: String
    var channel: String
    var text: String
    var startMs: Int
    var endMs: Int
    var confidence: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case speaker
        case channel
        case text
        case startMs = "start_ms"
        case endMs = "end_ms"
        case confidence
    }

    init(from segment: TranscriptSegment) {
        self.id = segment.id.uuidString
        self.sessionId = segment.sessionId.uuidString
        self.speaker = segment.speaker.rawValue
        self.channel = segment.channel.rawValue
        self.text = segment.text
        self.startMs = segment.startMs
        self.endMs = segment.endMs
        self.confidence = segment.confidence.map { Double($0) }
    }

    func toDomain() -> TranscriptSegment? {
        guard
            let uuid = UUID(uuidString: id),
            let sessionUuid = UUID(uuidString: sessionId),
            let speakerType = TranscriptSegment.Speaker(rawValue: speaker),
            let channelType = TranscriptSegment.Channel(rawValue: channel)
        else { return nil }
        return TranscriptSegment(
            id: uuid,
            sessionId: sessionUuid,
            speaker: speakerType,
            channel: channelType,
            text: text,
            startMs: startMs,
            endMs: endMs,
            confidence: confidence.map { Float($0) }
        )
    }
}
