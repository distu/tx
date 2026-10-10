import XCTest
@testable import TxCore

final class MeetAccessibilityTests: XCTestCase {
    func testLocalMicrophoneLabelsDoNotMatchParticipantControls() {
        XCTAssertEqual(MeetAccessibilityReader.localMicMuted(label: "Ativar microfone"), true)
        XCTAssertEqual(MeetAccessibilityReader.localMicMuted(label: "Desativar microfone"), false)
        XCTAssertEqual(MeetAccessibilityReader.localMicMuted(label: "Turn on microphone"), true)
        XCTAssertEqual(MeetAccessibilityReader.localMicMuted(label: "Turn off microphone"), false)
        XCTAssertNil(MeetAccessibilityReader.localMicMuted(label: "Desativar som do microfone de outra pessoa"))
        XCTAssertEqual(MeetAccessibilityReader.localMicMuted(label: "Ativar som"), true)
        XCTAssertEqual(MeetAccessibilityReader.localMicMuted(label: "Desativar som"), false)
        XCTAssertTrue(MeetAccessibilityReader.isLeaveCallButton("Sair da chamada"))
        XCTAssertFalse(MeetAccessibilityReader.isLeaveCallButton("Voltar ao chat"))
        XCTAssertEqual(MeetAccessibilityReader.localMicMuted(label: "Desativar mudo\u{00a0}do microfone"), true)
        XCTAssertEqual(MeetAccessibilityReader.localMicMuted(label: "Ativar mudo do\u{00a0}microfone"), false)
        XCTAssertTrue(MeetAccessibilityReader.isLeaveCallButton("Sair"))
    }

    func testOnlyMeetRoomURLsAreRecognized() {
        XCTAssertEqual(MeetAccessibilityReader.roomCode(in: "meet.google.com/abc-defg-hij?authuser=0"), "abc-defg-hij")
        XCTAssertNil(MeetAccessibilityReader.roomCode(in: "https://meet.google.com/landing"))
        XCTAssertNil(MeetAccessibilityReader.roomCode(in: "https://example.com/abc-defg-hij"))
        XCTAssertTrue(MeetAccessibilityReader.isBrowserAddressBar(label: "Barra de endereço e de pesquisa"))
        XCTAssertTrue(MeetAccessibilityReader.isBrowserAddressBar(label: "Address and search bar"))
        XCTAssertFalse(MeetAccessibilityReader.isBrowserAddressBar(label: "Meeting link"))
        XCTAssertTrue(AppleScriptBridge.isTeamsURL(URL(string: "https://teams.microsoft.com/v2/")!))
        XCTAssertFalse(AppleScriptBridge.isTeamsURL(URL(string: "https://teams.microsoft.com.evil.test/v2/")!))
    }

    func testLiveAccessibilityWhenExplicitlyConfigured() throws {
        let env = ProcessInfo.processInfo.environment
        guard let pidString = env["TX_AX_QA_PID"], let pid = pid_t(pidString),
              let rawURL = env["TX_AX_QA_URL"], let url = URL(string: rawURL) else {
            throw XCTSkip("Live Meet QA not configured")
        }
        XCTAssertTrue(MeetAccessibilityReader.isAvailable)
        let result = MeetAccessibilityReader.micMuted(browserPID: pid, meetingURL: url)
        if let expected = env["TX_AX_QA_EXPECT_MUTED"] {
            XCTAssertEqual(result, expected == "true")
        } else {
            XCTAssertNotNil(result)
        }
    }

    func testLiveArcMicWithoutExtensionWhenConfigured() async throws {
        guard let expected = ProcessInfo.processInfo.environment["TX_ARC_MIC_QA_EXPECT"] else {
            throw XCTSkip("Arc microphone QA not configured")
        }
        let state = await AppleScriptBridge.microphoneMuted(
            browserBundleId: "company.thebrowser.Browser",
            meetingURL: nil
        )
        if expected == "unknown" { XCTAssertNil(state) }
        else { XCTAssertEqual(state, expected == "muted") }
    }
}
