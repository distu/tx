import Foundation
import AVFoundation
import Accelerate

/// Converte AVAudioPCMBuffer (qualquer sample rate / channel count) para
/// array de floats mono a 16 kHz, formato exigido pelo WhisperKit.
public enum PCMResampler {
    public static let targetSampleRate: Double = 16_000

    /// Peak alvo após normalização. -3 dBFS = 0.7079 linear.
    /// Mantém margem de 3dB abaixo do clip pra evitar distorção.
    public static let normalizationTargetPeak: Float = 0.707

    /// Peak mínimo pra NÃO normalizar (áudio já alto). Acima disso, fica como está.
    public static let normalizationThreshold: Float = 0.5

    /// Ganho máximo aplicado (10x = +20dB). Evita amplificar demais ruído de fundo
    /// quando o microfone tá em silêncio total.
    public static let normalizationMaxGain: Float = 10.0

    public static func toMono16k(buffers: [AVAudioPCMBuffer], normalize: Bool = true) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(buffers.reduce(0) { $0 + Int($1.frameLength) })

        for buffer in buffers {
            guard let converted = convertToMono16k(buffer) else { continue }
            out.append(contentsOf: converted)
        }

        if normalize {
            applyPeakNormalization(&out)
        }
        return out
    }

    public struct NormalizationInfo: Sendable {
        public let peakBefore: Float
        public let peakAfter: Float
        public let gain: Float
    }

    /// Aplica ganho digital se o peak do áudio estiver abaixo do threshold.
    /// Compensa AGC agressivo (Chrome/Meet) que atenua volume do mic.
    /// Limita ganho a `normalizationMaxGain` pra não amplificar ruído.
    @discardableResult
    private static func applyPeakNormalization(_ samples: inout [Float]) -> NormalizationInfo {
        guard !samples.isEmpty else {
            return NormalizationInfo(peakBefore: 0, peakAfter: 0, gain: 1)
        }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))

        guard peak > 0.001, peak < normalizationThreshold else {
            return NormalizationInfo(peakBefore: peak, peakAfter: peak, gain: 1)
        }

        let rawGain = normalizationTargetPeak / peak
        let gain = min(rawGain, normalizationMaxGain)
        var g = gain
        vDSP_vsmul(samples, 1, &g, &samples, 1, vDSP_Length(samples.count))

        var peakAfter: Float = 0
        vDSP_maxmgv(samples, 1, &peakAfter, vDSP_Length(samples.count))
        return NormalizationInfo(peakBefore: peak, peakAfter: peakAfter, gain: gain)
    }

    /// Retorna o áudio mono 16k + info de normalização. Usado para logar o ganho aplicado.
    public static func toMono16kWithInfo(buffers: [AVAudioPCMBuffer]) -> (samples: [Float], info: NormalizationInfo) {
        var out: [Float] = []
        out.reserveCapacity(buffers.reduce(0) { $0 + Int($1.frameLength) })
        for buffer in buffers {
            guard let converted = convertToMono16k(buffer) else { continue }
            out.append(contentsOf: converted)
        }
        let info = applyPeakNormalization(&out)
        return (out, info)
    }

    private static func convertToMono16k(_ source: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = source.format
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        // Fast path: já estava no formato desejado.
        if sourceFormat.sampleRate == targetSampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            return extractFloats(source)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }

        // Calcula capacidade do buffer de saída.
        let ratio = targetSampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(source.frameLength) * ratio + 128)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return source
        }

        guard status != .error, error == nil else { return nil }
        return extractFloats(outBuffer)
    }

    private static func extractFloats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)

        if channels == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        }

        // Downmix preservando volume: para cada frame, usa o canal com maior
        // magnitude absoluta. Evita perda de 6dB (ou mais) se um canal tem
        // áudio e o outro é silencioso, como em HyperX stereo com voz só no L.
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var best: Float = 0
            var bestAbs: Float = 0
            for ch in 0..<channels {
                let sample = channelData[ch][i]
                let absSample = abs(sample)
                if absSample > bestAbs {
                    bestAbs = absSample
                    best = sample
                }
            }
            mono[i] = best
        }
        return mono
    }
}
