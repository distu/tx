import Foundation
import AVFoundation

/// Escreve buffers PCM em um arquivo M4A (AAC).
/// Converte sample rate e channel count conforme necessário.
public final class AudioFileWriter: @unchecked Sendable {
    public let url: URL
    public let targetFormat: AVAudioFormat

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "dev.distuai.tx.audiofilewriter")

    public init(url: URL, targetSampleRate: Double, channels: AVAudioChannelCount) throws {
        self.url = url
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw TxError.audioEngineFailure("Falha criando targetFormat \(targetSampleRate)Hz \(channels)ch")
        }
        self.targetFormat = targetFormat
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws {
        try queue.sync {
            if file == nil {
                try openFile(sourceFormat: buffer.format)
            }

            let bufferToWrite: AVAudioPCMBuffer
            if buffer.format == targetFormat {
                bufferToWrite = buffer
            } else {
                bufferToWrite = try convert(buffer)
            }

            try file?.write(from: bufferToWrite)
        }
    }

    public func close() {
        queue.sync {
            file = nil
            converter = nil
        }
    }

    private func openFile(sourceFormat: AVAudioFormat) throws {
        // Bitrate omitido de propósito: AAC a 16 kHz mono não aceita 64 kbps
        // (cap perto de ~32 kbps), então deixamos o encoder escolher a taxa
        // apropriada para o sample rate / layout.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetFormat.sampleRate,
            AVNumberOfChannelsKey: Int(targetFormat.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings)

        if sourceFormat != targetFormat {
            self.converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            self.converterSourceFormat = sourceFormat
        }
    }

    private func convert(_ sourceBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter else {
            throw TxError.audioEngineFailure("Converter não inicializado")
        }

        let ratio = targetFormat.sampleRate / sourceBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw TxError.audioEngineFailure("Falha criando outputBuffer")
        }

        let state = ConverterInputState(buffer: sourceBuffer)

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            state.nextBuffer(outStatus: outStatus)
        }

        let result = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        if result == .error, let error {
            throw TxError.audioEngineFailure("Convert failed: \(error.localizedDescription)")
        }
        return outputBuffer
    }
}

/// Estado mutável da closure de input do `AVAudioConverter`.
/// Encapsulado em uma classe `@unchecked Sendable` porque o converter chama
/// a closure de forma síncrona em uma única thread durante `convert(to:)`.
private final class ConverterInputState: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if supplied {
            outStatus.pointee = .noDataNow
            return nil
        }
        supplied = true
        outStatus.pointee = .haveData
        return buffer
    }
}
