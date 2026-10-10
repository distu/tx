import XCTest
@testable import TxCore

final class ProcessIsolationTests: XCTestCase {
    func testSeparateChromeInstancesUnderSameLauncherStaySeparate() {
        let parents: [pid_t: pid_t] = [101: 100, 201: 200, 100: 50, 200: 50, 50: 1]
        let bundles: [pid_t: String] = [100: "com.google.Chrome", 200: "com.google.Chrome", 50: "dev.distuai.tx"]
        let parent: (pid_t) -> pid_t? = { parents[$0] }
        let bundle: (pid_t) -> String? = { bundles[$0] }

        XCTAssertEqual(
            ProcessArgsReader.matchingAncestor(for: 101, bundleId: "com.google.Chrome.helper", parent: parent, appBundle: bundle),
            100
        )
        XCTAssertEqual(
            ProcessArgsReader.matchingAncestor(for: 201, bundleId: "com.google.Chrome.helper", parent: parent, appBundle: bundle),
            200
        )
        XCTAssertNil(
            ProcessArgsReader.matchingAncestor(for: 101, bundleId: nil, parent: parent, appBundle: bundle)
        )
        XCTAssertTrue(ProcessArgsReader.isDescendant(101, of: 100, parent: parent))
        XCTAssertFalse(ProcessArgsReader.isDescendant(201, of: 100, parent: parent))
    }

    func testOnlyMeetRoomURLsAreOfferedAsMeetingTitles() {
        XCTAssertTrue(AppleScriptBridge.isRoomURL(URL(string: "https://meet.google.com/abc-defg-hij")!))
        XCTAssertTrue(AppleScriptBridge.isRoomURL(URL(string: "https://meet.google.com/abc-defg-hij?authuser=1")!))
        XCTAssertFalse(AppleScriptBridge.isRoomURL(URL(string: "https://meet.google.com/new")!))
        XCTAssertFalse(AppleScriptBridge.isRoomURL(URL(string: "https://meet.google.com/lookup/abc-defg-hij")!))
        XCTAssertFalse(AppleScriptBridge.isRoomURL(URL(string: "https://notmeet.google.com/abc-defg-hij")!))
    }

}
