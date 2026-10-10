import Foundation
import AVFoundation

/// Calcula nível de áudio (RMS em dBFS) a partir de buffers PCM float32.
/// Usado para waveform em tempo real e detecção de silêncio.
public enum AudioLevelMeter {

    public static func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return -160 }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -160 }

        var totalSum: Float = 0
        for channel in 0..<channels {
            let samples = channelData[channel]
            var sumSquares: Float = 0
            for i in 0..<frames {
                let sample = samples[i]
                sumSquares += sample * sample
            }
            totalSum += sumSquares / Float(frames)
        }

        let meanSquare = totalSum / Float(channels)
        let rms = sqrt(meanSquare)
        let db = 20 * log10(max(rms, 0.0000001))
        return db
    }

    /// Converte dB para intensidade normalizada 0...1 (útil para waveform visual).
    public static func normalized(fromDB db: Float, floor: Float = -60) -> Float {
        let clamped = max(floor, min(0, db))
        return (clamped - floor) / (0 - floor)
    }
}
