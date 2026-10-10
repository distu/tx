import Foundation
import AVFoundation

/// Wrapper Sendable para `AVAudioPCMBuffer`.
///
/// `AVAudioPCMBuffer` não é formalmente `Sendable` no Swift 6, mas na prática
/// o consumidor único de nossos `AsyncStream` (um único loop por stream) nunca
/// acessa o mesmo buffer concorrentemente. Usar `@unchecked Sendable` aqui evita
/// cópias desnecessárias em cada callback de IO do Core Audio.
public struct AudioBufferBox: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let wasMutedAtCapture: Bool

    public init(_ buffer: AVAudioPCMBuffer, wasMutedAtCapture: Bool = false) {
        self.buffer = buffer
        self.wasMutedAtCapture = wasMutedAtCapture
    }

    /// Copia o buffer antes de sair do callback do AVAudioEngine. Quando mutado,
    /// nenhuma amostra original entra na fila de escrita.
    public static func stableCopy(of sourceBuffer: AVAudioPCMBuffer, muted: Bool) -> AudioBufferBox? {
        guard let stable = AVAudioPCMBuffer(
            pcmFormat: sourceBuffer.format, frameCapacity: sourceBuffer.frameLength
        ) else { return nil }
        stable.frameLength = sourceBuffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: sourceBuffer.audioBufferList)
        )
        let target = UnsafeMutableAudioBufferListPointer(stable.mutableAudioBufferList)
        for index in 0..<min(source.count, target.count) {
            guard let destination = target[index].mData else { continue }
            let byteCount = min(
                Int(source[index].mDataByteSize), Int(target[index].mDataByteSize)
            )
            if muted {
                memset(destination, 0, byteCount)
            } else if let original = source[index].mData {
                memcpy(destination, original, byteCount)
            } else {
                memset(destination, 0, byteCount)
            }
        }
        return AudioBufferBox(stable, wasMutedAtCapture: muted)
    }

    /// O buffer do microfone pertence ao consumidor único. Zera também os
    /// buffers recebidos antes do evento de mute, mas ainda não escritos.
    public func silenceInPlace() {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in buffers {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
    }
}
