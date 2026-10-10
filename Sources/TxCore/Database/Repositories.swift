import Foundation
import GRDB

public struct ProjectRepository: Sendable {
    let dbPool: DatabasePool

    public init(database: DatabaseManager) {
        self.dbPool = database.dbPool
    }

    public func insert(_ project: Project) throws {
        try dbPool.write { db in
            try ProjectRecord(from: project).insert(db)
        }
    }

    public func update(_ project: Project) throws {
        try dbPool.write { db in
            try ProjectRecord(from: project).update(db)
        }
    }

    public func delete(id: UUID) throws {
        _ = try dbPool.write { db in
            try ProjectRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func all() throws -> [Project] {
        try dbPool.read { db in
            try ProjectRecord.order(ProjectRecord.Columns.name).fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    public func find(id: UUID) throws -> Project? {
        try dbPool.read { db in
            try ProjectRecord.fetchOne(db, key: id.uuidString)?.toDomain()
        }
    }
}

public struct ProjectRuleRepository: Sendable {
    let dbPool: DatabasePool

    public init(database: DatabaseManager) {
        self.dbPool = database.dbPool
    }

    public func insert(_ rule: ProjectRule) throws {
        try dbPool.write { db in
            try ProjectRuleRecord(from: rule).insert(db)
        }
    }

    public func delete(id: UUID) throws {
        _ = try dbPool.write { db in
            try ProjectRuleRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func allOrderedByPriority() throws -> [ProjectRule] {
        try dbPool.read { db in
            try ProjectRuleRecord
                .order(Column("priority").desc)
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }

    public func forProject(_ projectId: UUID) throws -> [ProjectRule] {
        try dbPool.read { db in
            try ProjectRuleRecord
                .filter(Column("project_id") == projectId.uuidString)
                .order(Column("priority").desc)
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }
}

public struct ChromeProfileRepository: Sendable {
    let dbPool: DatabasePool

    public init(database: DatabaseManager) {
        self.dbPool = database.dbPool
    }

    public func insert(_ profile: ChromeProfile) throws {
        try dbPool.write { db in
            try ChromeProfileRecord(from: profile).insert(db)
        }
    }

    public func update(_ profile: ChromeProfile) throws {
        try dbPool.write { db in
            try ChromeProfileRecord(from: profile).update(db)
        }
    }

    public func delete(id: UUID) throws {
        _ = try dbPool.write { db in
            try ChromeProfileRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func all() throws -> [ChromeProfile] {
        try dbPool.read { db in
            try ChromeProfileRecord.fetchAll(db).map { $0.toDomain() }
        }
    }

    public func findByUserDataDir(_ path: String) throws -> ChromeProfile? {
        try dbPool.read { db in
            try ChromeProfileRecord
                .filter(Column("user_data_dir") == path)
                .fetchOne(db)?
                .toDomain()
        }
    }
}

public struct SessionRepository: Sendable {
    let dbPool: DatabasePool

    public init(database: DatabaseManager) {
        self.dbPool = database.dbPool
    }

    public func insert(_ session: Session) throws {
        try dbPool.write { db in
            try SessionRecord(from: session).insert(db)
        }
    }

    public func update(_ session: Session) throws {
        try dbPool.write { db in
            try SessionRecord(from: session).update(db)
        }
    }

    public func delete(id: UUID) throws {
        _ = try dbPool.write { db in
            try SessionRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func find(id: UUID) throws -> Session? {
        try dbPool.read { db in
            try SessionRecord.fetchOne(db, key: id.uuidString)?.toDomain()
        }
    }

    public func all() throws -> [Session] {
        try dbPool.read { db in
            try SessionRecord
                .order(Column("started_at").desc)
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    public func forProject(_ projectId: UUID) throws -> [Session] {
        try dbPool.read { db in
            try SessionRecord
                .filter(Column("project_id") == projectId.uuidString)
                .order(Column("started_at").desc)
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }
}

public struct SegmentRepository: Sendable {
    let dbPool: DatabasePool

    public init(database: DatabaseManager) {
        self.dbPool = database.dbPool
    }

    public func insertMany(_ segments: [TranscriptSegment]) throws {
        try dbPool.write { db in
            for segment in segments {
                try SegmentRecord(from: segment).insert(db)
            }
        }
    }

    /// Substitui o resultado apenas após todos os segmentos estarem prontos.
    /// Em erro, o SQLite reverte a remoção e preserva a transcrição anterior.
    public func replaceForSession(_ sessionId: UUID, with segments: [TranscriptSegment]) throws {
        try dbPool.write { db in
            _ = try SegmentRecord
                .filter(Column("session_id") == sessionId.uuidString)
                .deleteAll(db)
            for segment in segments {
                try SegmentRecord(from: segment).insert(db)
            }
        }
    }

    public func forSession(_ sessionId: UUID) throws -> [TranscriptSegment] {
        try dbPool.read { db in
            try SegmentRecord
                .filter(Column("session_id") == sessionId.uuidString)
                .order(Column("start_ms"))
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }

    public func deleteForSession(_ sessionId: UUID) throws {
        _ = try dbPool.write { db in
            try SegmentRecord
                .filter(Column("session_id") == sessionId.uuidString)
                .deleteAll(db)
        }
    }

    /// Busca full-text via FTS5 `segments_fts`. Retorna sessões distintas com match + snippets.
    public func searchFullText(_ query: String, limit: Int = 100) throws -> [SegmentSearchHit] {
        try dbPool.read { db in
            let sanitized = Self.sanitizeFTS5(query)
            guard !sanitized.isEmpty else { return [] }
            let sql = """
            SELECT s.id, s.session_id, s.speaker, s.channel, s.text, s.start_ms, s.end_ms, s.confidence,
                   snippet(segments_fts, 0, '[[', ']]', '...', 12) AS snippet
            FROM segments s
            JOIN segments_fts f ON f.rowid = s.rowid
            WHERE segments_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [sanitized, limit])
            return rows.compactMap { row -> SegmentSearchHit? in
                guard
                    let uuid = UUID(uuidString: row["id"]),
                    let sessionUuid = UUID(uuidString: row["session_id"]),
                    let speaker = TranscriptSegment.Speaker(rawValue: row["speaker"]),
                    let channel = TranscriptSegment.Channel(rawValue: row["channel"])
                else { return nil }
                let segment = TranscriptSegment(
                    id: uuid,
                    sessionId: sessionUuid,
                    speaker: speaker,
                    channel: channel,
                    text: row["text"],
                    startMs: row["start_ms"],
                    endMs: row["end_ms"],
                    confidence: (row["confidence"] as Double?).map { Float($0) }
                )
                return SegmentSearchHit(segment: segment, snippet: row["snippet"])
            }
        }
    }

    static func sanitizeFTS5(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let cleaned = trimmed
            .replacingOccurrences(of: "\"", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0)\"" }
            .joined(separator: " ")
        return cleaned
    }
}

public struct SegmentSearchHit: Sendable, Hashable {
    public let segment: TranscriptSegment
    public let snippet: String

    public init(segment: TranscriptSegment, snippet: String) {
        self.segment = segment
        self.snippet = snippet
    }
}

// MARK: - TagRepository

public struct TagRepository: Sendable {
    let dbPool: DatabasePool

    public init(database: DatabaseManager) {
        self.dbPool = database.dbPool
    }

    public func insert(_ tag: Tag) throws {
        try dbPool.write { db in
            try TagRecord(from: tag).insert(db)
        }
    }

    public func update(_ tag: Tag) throws {
        try dbPool.write { db in
            try TagRecord(from: tag).update(db)
        }
    }

    public func delete(id: UUID) throws {
        _ = try dbPool.write { db in
            try TagRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func all() throws -> [Tag] {
        try dbPool.read { db in
            try TagRecord
                .order(TagRecord.Columns.name)
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    public func tagsForSession(_ sessionId: UUID) throws -> [Tag] {
        try dbPool.read { db in
            let sql = """
            SELECT t.* FROM tags t
            JOIN session_tags st ON st.tag_id = t.id
            WHERE st.session_id = ?
            ORDER BY t.name
            """
            return try TagRecord.fetchAll(db, sql: sql, arguments: [sessionId.uuidString])
                .map { $0.toDomain() }
        }
    }

    /// Substitui todas as tags de uma sessão pelo novo conjunto de IDs.
    public func setTags(for sessionId: UUID, tagIds: [UUID]) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM session_tags WHERE session_id = ?",
                arguments: [sessionId.uuidString]
            )
            for tagId in tagIds {
                try db.execute(
                    sql: "INSERT INTO session_tags (session_id, tag_id) VALUES (?, ?)",
                    arguments: [sessionId.uuidString, tagId.uuidString]
                )
            }
        }
    }
}
