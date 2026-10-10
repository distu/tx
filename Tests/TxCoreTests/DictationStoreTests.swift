import XCTest
@testable import TxCore

final class DictationStoreTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        super.tearDown()
    }

    // NOTE: `DatabaseManager.inMemory()` usa `:memory:` em um `DatabasePool`,
    // que compartilha estado entre conexões. Para isolamento real entre testes
    // usamos um arquivo tmp único com limpeza em tearDown.
    func makeStore() throws -> DictationStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tx-test-\(UUID().uuidString).sqlite")
        tempURLs.append(tmp)
        let db = try DatabaseManager(url: tmp)
        return DictationStore(database: db)
    }

    func testInsertAndRecent() throws {
        let store = try makeStore()
        let now = Date()
        let d = Dictation(
            startedAt: now,
            durationMs: 3_000,
            wordCount: 5,
            wpm: 100,
            text: "teste do ditado em pt br",
            mode: .pushToTalk,
            targetApp: "TextEdit",
            targetBundle: "com.apple.TextEdit"
        )
        try store.insert(d)

        let recent = try store.recent(limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.text, "teste do ditado em pt br")
        XCTAssertEqual(recent.first?.mode, .pushToTalk)
    }

    func testSearchFTS() throws {
        let store = try makeStore()
        try store.insert(Dictation(
            startedAt: Date(),
            durationMs: 1_000,
            wordCount: 3,
            wpm: 180,
            text: "o computador está lento",
            mode: .pushToTalk
        ))
        try store.insert(Dictation(
            startedAt: Date().addingTimeInterval(-100),
            durationMs: 1_000,
            wordCount: 3,
            wpm: 180,
            text: "comprar leite no mercado",
            mode: .locked
        ))

        let hits = try store.search(query: "mercado", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.mode, .locked)
    }

    func testStatsAggregate() throws {
        let store = try makeStore()
        try store.insert(Dictation(
            startedAt: Date(),
            durationMs: 2_000,
            wordCount: 4,
            wpm: 120,
            text: "um dois três quatro",
            mode: .pushToTalk
        ))
        try store.insert(Dictation(
            startedAt: Date(),
            durationMs: 4_000,
            wordCount: 6,
            wpm: 90,
            text: "cinco seis sete oito nove dez",
            mode: .pushToTalk
        ))

        let stats = try store.stats()
        XCTAssertEqual(stats.totalCount, 2)
        XCTAssertEqual(stats.totalWords, 10)
        XCTAssertEqual(stats.totalDurationMs, 6_000)
        XCTAssertEqual(stats.avgWpm, 105, accuracy: 0.01)
    }
}
