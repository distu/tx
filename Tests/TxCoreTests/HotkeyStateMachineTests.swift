import XCTest
@testable import TxCore

final class HotkeyStateMachineTests: XCTestCase {

    func makeMachine(hold: Int = 200, doubleTap: Int = 300) -> HotkeyStateMachine {
        HotkeyStateMachine(config: .init(holdThresholdMs: hold, doubleTapWindowMs: doubleTap))
    }

    func testHoldEmitsStartAndEnd() {
        let m = makeMachine()
        m.onFnDown(at: 0)
        XCTAssertNil(m.onHoldCheck(at: 0.1))     // ainda não é hold
        let start = m.onHoldCheck(at: 0.25)      // cruzou o threshold
        XCTAssertEqual(start, .holdStarted(timestamp: 0))

        let end = m.onFnUp(at: 1.0)
        XCTAssertEqual(end, .holdEnded(timestamp: 1.0))
    }

    func testShortTapAloneEmitsNothing() {
        let m = makeMachine()
        m.onFnDown(at: 0)
        let event = m.onFnUp(at: 0.1)
        XCTAssertNil(event)
    }

    func testDoubleTapEmitsWithinWindow() {
        let m = makeMachine(hold: 200, doubleTap: 300)
        m.onFnDown(at: 0.0)
        _ = m.onFnUp(at: 0.1)              // tap 1: armazena

        m.onFnDown(at: 0.2)
        let event = m.onFnUp(at: 0.3)      // tap 2: dentro da janela
        XCTAssertEqual(event, .doubleTap(timestamp: 0.3))
    }

    func testDoubleTapBeyondWindowDoesNotEmit() {
        let m = makeMachine(hold: 200, doubleTap: 300)
        m.onFnDown(at: 0.0)
        _ = m.onFnUp(at: 0.1)

        m.onFnDown(at: 0.6)               // gap = 500ms > 300ms
        let event = m.onFnUp(at: 0.7)
        XCTAssertNil(event)
    }

    func testHoldAfterShortTapResetsDoubleTap() {
        let m = makeMachine()
        m.onFnDown(at: 0.0)
        _ = m.onFnUp(at: 0.05)            // short tap

        m.onFnDown(at: 0.10)
        _ = m.onHoldCheck(at: 0.35)       // vira hold (após threshold)
        let end = m.onFnUp(at: 0.50)
        XCTAssertEqual(end, .holdEnded(timestamp: 0.50))

        // próximo tap curto não deve gerar double-tap
        m.onFnDown(at: 0.60)
        let e = m.onFnUp(at: 0.65)
        XCTAssertNil(e)
    }

    func testEscapeWhenRecordingEmits() {
        let m = makeMachine()
        m.isRecording = true
        XCTAssertEqual(m.onEscape(), .escapePressed)
    }

    func testEscapeWhenIdleIgnored() {
        let m = makeMachine()
        m.isRecording = false
        XCTAssertNil(m.onEscape())
    }

    func testLongPressWithoutHoldCheckEmitsRetroactively() {
        // Se o timer externo atrasa e não chama onHoldCheck, ao soltar
        // com duração > threshold devemos emitir retroativamente .holdStarted.
        let m = makeMachine(hold: 200, doubleTap: 300)
        m.onFnDown(at: 0.0)
        let event = m.onFnUp(at: 0.4)      // durou 400ms mas holdCheck não rodou
        XCTAssertEqual(event, .holdStarted(timestamp: 0.0))
    }

    func testDoubleTapIsNotTriggeredAfterHold() {
        let m = makeMachine()
        m.onFnDown(at: 0.0)
        _ = m.onHoldCheck(at: 0.25)
        _ = m.onFnUp(at: 0.4)

        // Próximo ciclo: tap curto solto não deve gerar double-tap
        // (o hold limpa lastShortTapTimestamp).
        m.onFnDown(at: 0.5)
        let e = m.onFnUp(at: 0.55)
        XCTAssertNil(e)
    }
}
