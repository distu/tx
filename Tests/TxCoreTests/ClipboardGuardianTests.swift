import XCTest
import AppKit
@testable import TxCore

final class ClipboardGuardianTests: XCTestCase {

    func testSnapshotAndRestoreString() {
        let pb = NSPasteboard(name: NSPasteboard.Name("TxDictationTests"))
        pb.clearContents()
        pb.setString("original", forType: .string)

        let snapshot = PasteboardSnapshot.capture(pb)

        pb.clearContents()
        pb.setString("transiente", forType: .string)
        XCTAssertEqual(pb.string(forType: .string), "transiente")

        snapshot.restore(to: pb)
        XCTAssertEqual(pb.string(forType: .string), "original")
    }

    func testDictationMetricsAreConsistent() {
        let text = "uma vaca azul comeu alface na quinta feira"
        let words = Dictation.computeWordCount(text)
        XCTAssertEqual(words, 8)

        let wpm = Dictation.computeWpm(words: words, durationMs: 6_000)
        XCTAssertEqual(wpm, 80, accuracy: 0.01) // 8 palavras em 0.1 min = 80 wpm
    }
}
