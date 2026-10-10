import Testing
import Foundation
@testable import TxCore

@Suite("Database Migrations")
struct DatabaseMigrationTests {
    private func makeTempDatabase() throws -> (DatabaseManager, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tx-test-\(UUID().uuidString).sqlite")
        let manager = try DatabaseManager(url: url)
        return (manager, url)
    }

    @Test("Migration cria tabelas principais e FTS5")
    func migrationCreatesTables() throws {
        let (manager, url) = try makeTempDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        try manager.dbPool.read { db in
            for table in ["projects", "project_rules", "chrome_profiles", "sessions", "segments", "segments_fts"] {
                let exists = try db.tableExists(table) || db.viewExists(table)
                #expect(exists, "Tabela/view \(table) deveria existir")
            }
        }
    }

    @Test("Insert + find em Project funciona")
    func projectInsertFind() throws {
        let (manager, url) = try makeTempDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let repo = ProjectRepository(database: manager)
        let project = Project(name: "Teste", color: "#FF0000")
        try repo.insert(project)

        let found = try repo.find(id: project.id)
        #expect(found?.name == "Teste")
        #expect(found?.color == "#FF0000")
    }

    @Test("Inserir segmento sincroniza FTS5")
    func fts5SyncOnInsert() throws {
        let (manager, url) = try makeTempDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let sessionRepo = SessionRepository(database: manager)
        let segmentRepo = SegmentRepository(database: manager)

        let session = Session(title: "Reunião", processName: "Chrome")
        try sessionRepo.insert(session)

        let segment = TranscriptSegment(
            sessionId: session.id,
            speaker: .you,
            channel: .mic,
            text: "arquitetura de microserviços",
            startMs: 1000,
            endMs: 3000,
            confidence: -0.2
        )
        try segmentRepo.insertMany([segment])

        let hits = try segmentRepo.searchFullText("microserviços")
        #expect(hits.count == 1)
        #expect(hits.first?.segment.sessionId == session.id)
    }
}
