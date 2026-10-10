import Testing
@testable import TxCore

@Suite("FTS5 Query Sanitizer")
struct FTS5SanitizerTests {
    @Test("Query vazia retorna vazio")
    func emptyQuery() {
        #expect(SegmentRepository.sanitizeFTS5("") == "")
        #expect(SegmentRepository.sanitizeFTS5("   ") == "")
    }

    @Test("Palavras isoladas viram phrase tokens")
    func singleWord() {
        #expect(SegmentRepository.sanitizeFTS5("arquitetura") == "\"arquitetura\"")
    }

    @Test("Múltiplas palavras viram tokens separados")
    func multipleWords() {
        let result = SegmentRepository.sanitizeFTS5("microserviços event-driven")
        #expect(result.contains("\"microserviços\""))
        #expect(result.contains("\"event-driven\""))
    }

    @Test("Aspas no input são removidas para evitar FTS5 syntax error")
    func stripsQuotes() {
        let result = SegmentRepository.sanitizeFTS5("\"hello\"")
        #expect(!result.contains("\"\""))
    }
}
