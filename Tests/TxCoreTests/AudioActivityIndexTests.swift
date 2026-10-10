import AVFoundation
import XCTest
@testable import TxCore

final class AudioActivityIndexTests: XCTestCase {
    func testSilentAudioHasNoActivity() throws {
        let url = try writeAudio(pulse: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let activity: AudioActivityIndex
        do { activity = try AudioActivityIndex(audioURL: url) }
        catch { XCTFail("Falha ao ler áudio: \(error)"); return }
        XCTAssertFalse(activity.hasActivity)
        XCTAssertFalse(activity.hasActivity(startMs: 0, endMs: 2_000))
    }

    func testSpeechWindowRetainsSignalAndRejectsDistantSilence() throws {
        let url = try writeAudio(pulse: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let activity: AudioActivityIndex
        do { activity = try AudioActivityIndex(audioURL: url) }
        catch { XCTFail("Falha ao ler áudio: \(error)"); return }
        XCTAssertTrue(activity.hasActivity)
        XCTAssertFalse(activity.hasActivity(startMs: 0, endMs: 500))
        XCTAssertTrue(activity.hasActivity(startMs: 1_000, endMs: 1_400))
    }

    private func writeAudio(pulse: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tx-activity-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 32_000
        ))
        buffer.frameLength = 32_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<32_000 {
            samples[frame] = pulse && (16_000..<22_400).contains(frame) ? 0.1 : 0
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        } catch {
            XCTFail("Falha ao escrever áudio: \(error)")
            throw error
        }
        return url
    }

    func testRealSilentAACWhenExplicitlyConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["TX_SILENT_AAC_QA_PATH"] else {
            throw XCTSkip("Arquivo de áudio real não configurado")
        }
        let activity = try AudioActivityIndex(audioURL: URL(fileURLWithPath: path))
        XCTAssertFalse(activity.hasActivity)
    }
}
