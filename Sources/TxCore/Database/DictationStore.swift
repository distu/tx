import Foundation
import GRDB

struct DictationRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "dictations"

    var id: String
    var startedAt: Double
    var durationMs: Int
    var wordCount: Int
    var wpm: Double
    var text: String
    var mode: String
    var targetApp: String?
    var targetBundle: String?
    var pasted: Int
    var canceled: Int
    var audioPath: String?
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case durationMs = "duration_ms"
        case wordCount = "word_count"
        case wpm
        case text
        case mode
        case targetApp = "target_app"
        case targetBundle = "target_bundle"
        case pasted
        case canceled
        case audioPath = "audio_path"
        case createdAt = "created_at"
    }

    enum Columns {
        static let startedAt = Column("started_at")
        static let text = Column("text")
    }

    init(from d: Dictation) {
        self.id = d.id.uuidString
        self.startedAt = d.startedAt.timeIntervalSince1970
        self.durationMs = d.durationMs
        self.wordCount = d.wordCount
        self.wpm = d.wpm
        self.text = d.text
        self.mode = d.mode.rawValue
        self.targetApp = d.targetApp
        self.targetBundle = d.targetBundle
        self.pasted = d.pasted ? 1 : 0
        self.canceled = d.canceled ? 1 : 0
        self.audioPath = d.audioPath?.path
        self.createdAt = d.createdAt.timeIntervalSince1970
    }

    func toDomain() -> Dictation? {
        guard let uuid = UUID(uuidString: id),
              let mode = Dictation.Mode(rawValue: mode) else { return nil }
        return Dictation(
            id: uuid,
            startedAt: Date(timeIntervalSince1970: startedAt),
            durationMs: durationMs,
            wordCount: wordCount,
            wpm: wpm,
            text: text,
            mode: mode,
            targetApp: targetApp,
            targetBundle: targetBundle,
            pasted: pasted != 0,
            canceled: canceled != 0,
            audioPath: audioPath.map { URL(fileURLWithPath: $0) },
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}

public struct DictationStats: Sendable, Equatable {
    public let totalCount: Int
    public let totalWords: Int
    public let totalDurationMs: Int
    public let avgWpm: Double
}

public final class DictationStore: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func insert(_ dictation: Dictation) throws {
        try database.dbPool.write { db in
            let record = DictationRecord(from: dictation)
            try record.insert(db)
        }
    }

    public func update(_ dictation: Dictation) throws {
        try database.dbPool.write { db in
            let record = DictationRecord(from: dictation)
            try record.update(db)
        }
    }

    public func find(id: UUID) throws -> Dictation? {
        try database.dbPool.read { db in
            let idString = id.uuidString
            guard let record = try DictationRecord.fetchOne(db, sql: """
                SELECT * FROM dictations WHERE id = ?
                """, arguments: [idString]) else {
                return nil
            }
            return record.toDomain()
        }
    }

    public func recent(limit: Int = 50) throws -> [Dictation] {
        try database.dbPool.read { db in
            let records = try DictationRecord
                .order(DictationRecord.Columns.startedAt.desc)
                .limit(limit)
                .fetchAll(db)
            return records.compactMap { $0.toDomain() }
        }
    }

    public func search(query: String, limit: Int = 50) throws -> [Dictation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try recent(limit: limit) }

        return try database.dbPool.read { db in
            let sanitized = trimmed.replacingOccurrences(of: "\"", with: "")
            let ftsPattern = "\"\(sanitized)\"*"
            let rows = try DictationRecord.fetchAll(db, sql: """
                SELECT d.* FROM dictations d
                JOIN dictations_fts fts ON fts.rowid = d.rowid
                WHERE dictations_fts MATCH ?
                ORDER BY d.started_at DESC
                LIMIT ?
                """, arguments: [ftsPattern, limit])
            return rows.compactMap { $0.toDomain() }
        }
    }

    public func stats() throws -> DictationStats {
        try database.dbPool.read { db in
            let count = try DictationRecord.fetchCount(db)
            let sumWords = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(word_count), 0) FROM dictations") ?? 0
            let sumDur = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(duration_ms), 0) FROM dictations") ?? 0
            let avgWpm = try Double.fetchOne(db, sql: "SELECT COALESCE(AVG(wpm), 0) FROM dictations WHERE word_count > 0") ?? 0
            return DictationStats(
                totalCount: count,
                totalWords: sumWords,
                totalDurationMs: sumDur,
                avgWpm: avgWpm
            )
        }
    }

    public func deleteAll() throws {
        _ = try database.dbPool.write { db in
            try DictationRecord.deleteAll(db)
        }
    }

    public func delete(id: UUID) throws {
        _ = try database.dbPool.write { db in
            try DictationRecord.deleteOne(db, key: id.uuidString)
        }
    }
}
