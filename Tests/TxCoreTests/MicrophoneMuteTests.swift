import AVFoundation
import XCTest
@testable import TxCore

final class MicrophoneMuteTests: XCTestCase {
    func testMutedCallbackCopiesOnlySilenceAndPreservesSource() {
        let source = makeBuffer(sample: 0.5)
        let muted = AudioBufferBox.stableCopy(of: source, muted: true)

        XCTAssertNotNil(muted)
        XCTAssertTrue(muted?.wasMutedAtCapture == true)
        XCTAssertTrue(samples(in: muted!.buffer).allSatisfy { $0 == 0 })
        XCTAssertTrue(samples(in: source).allSatisfy { $0 == 0.5 })
    }

    func testQueuedLiveBufferCanBeSilencedAfterMuteEvent() {
        let source = makeBuffer(sample: 0.5)
        let queued = AudioBufferBox.stableCopy(of: source, muted: false)!
        XCTAssertTrue(samples(in: queued.buffer).allSatisfy { $0 == 0.5 })

        queued.silenceInPlace()

        XCTAssertTrue(samples(in: queued.buffer).allSatisfy { $0 == 0 })
        XCTAssertTrue(samples(in: source).allSatisfy { $0 == 0.5 })
    }

    func testMeetHeartbeatExpiryClosesMicrophoneGate() async {
        await MainActor.run {
            let pipeline = AudioPipeline(pid: 1)
            pipeline.protectMicUntilMeetState(hasAssociation: true)
            XCTAssertEqual(pipeline.micGateStatus, .awaitingMeet)
            pipeline.setMicMute(false)
            XCTAssertEqual(pipeline.micGateStatus, .liveByMeet)
            pipeline.expireMeetMicStateIfNeeded(now: Date().addingTimeInterval(7))
            XCTAssertEqual(pipeline.micGateStatus, .staleMeet)
            XCTAssertTrue(pipeline.isMicMuted)
        }
    }

    private func makeBuffer(sample: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        buffer.frameLength = 128
        for index in 0..<128 {
            buffer.floatChannelData![0][index] = sample
        }
        return buffer
    }

    private func samples(in buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
