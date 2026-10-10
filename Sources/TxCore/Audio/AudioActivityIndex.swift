import AVFoundation
import Foundation

/// Índice de sinal do arquivo finalizado. O AAC pode decodificar silêncio
/// digital como ruído muito baixo; exigir sinal antes e depois do ASR evita
/// aceitar texto inventado em trechos sem áudio.
public struct AudioActivityIndex: Sendable {
    public static let binDurationMs = 100
    public static let peakThreshold: Float = 0.00031623 // -70 dBFS

    private let activeBins: [Bool]

    public var hasActivity: Bool { activeBins.contains(true) }

    public init(audioURL: URL) throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: audioURL) }
        catch { throw TxError.transcriptionFailure("Falha ao abrir áudio para análise: \(error.localizedDescription)") }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else {
            throw TxError.transcriptionFailure("Taxa de amostragem inválida")
        }
        let framesPerBin = max(1, Int(sampleRate * Double(Self.binDurationMs) / 1_000))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096) else {
            throw TxError.transcriptionFailure("Não foi possível analisar o áudio")
        }

        var bins: [Bool] = []
        var framePosition = 0
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let requested = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            do { try file.read(into: buffer, frameCount: requested) }
            catch { throw TxError.transcriptionFailure("Falha ao decodificar áudio para análise: \(error.localizedDescription)") }
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { break }
            guard let channels = buffer.floatChannelData else {
                throw TxError.transcriptionFailure("Formato de áudio não suportado")
            }
            for frame in 0..<frameCount {
                let bin = (framePosition + frame) / framesPerBin
                if bin == bins.count { bins.append(false) }
                if bins[bin] { continue }
                for channel in 0..<Int(buffer.format.channelCount) {
                    if abs(channels[channel][frame]) >= Self.peakThreshold {
                        bins[bin] = true
                        break
                    }
                }
            }
            framePosition += frameCount
        }
        activeBins = bins
    }

    /// Inclui uma pequena margem para compensar timestamps do ASR e do AAC.
    public func hasActivity(startMs: Int, endMs: Int, marginMs: Int = 150) -> Bool {
        guard !activeBins.isEmpty else { return false }
        let first = max(0, startMs - marginMs) / Self.binDurationMs
        let last = max(0, endMs + marginMs) / Self.binDurationMs
        guard first < activeBins.count else { return false }
        return activeBins[first...min(last, activeBins.count - 1)].contains(true)
    }
}
