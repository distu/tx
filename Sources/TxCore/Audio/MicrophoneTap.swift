import Foundation
import AVFoundation

/// Captura áudio do microfone via AVAudioEngine e expõe os buffers PCM por AsyncStream.
///
/// Gotcha crítico: `AVAudioEngine` só permite uma tap por nó de saída. A solução usada
/// aqui é conectar o `inputNode` a um `AVAudioMixerNode` intermediário e instalar a tap
/// no mixer, permitindo que outros nós consumam o input se necessário.
public final class MicrophoneTap: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private var tapInstalled = false
    private let pauseLock = NSLock()
    private var capturePaused = false

    private var continuation: AsyncStream<AudioBufferBox>.Continuation?
    public let stream: AsyncStream<AudioBufferBox>

    public private(set) var format: AVAudioFormat?
    public private(set) var isRunning: Bool = false
    /// Estado sincronizado com a thread de callback do AVAudioEngine.
    public var isCapturesPaused: Bool {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        return capturePaused
    }

    public init(preferredDeviceID: AudioDeviceID? = nil) {
        _ = preferredDeviceID
        var cont: AsyncStream<AudioBufferBox>.Continuation!
        self.stream = AsyncStream { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    deinit {
        stop()
        continuation?.finish()
    }

    public func start() throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        dbg("[mic] inputFormat: sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount)")

        engine.attach(mixer)
        engine.connect(input, to: mixer, format: inputFormat)

        let mainMixer = engine.mainMixerNode
        engine.connect(mixer, to: mainMixer, format: inputFormat)
        mainMixer.outputVolume = 0
        mixer.outputVolume = 1

        self.format = inputFormat

        mixer.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let muted = self.isCapturesPaused
            guard let stable = AudioBufferBox.stableCopy(of: buffer, muted: muted) else { return }
            self.continuation?.yield(stable)
        }
        tapInstalled = true

        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
        isRunning = true
        TxLogger.audio.info("MicrophoneTap started")
    }

    /// Mantém a linha do tempo, mas só envia amostras zeradas enquanto mutado.
    public func pauseCapture() {
        pauseLock.lock()
        capturePaused = true
        pauseLock.unlock()
        TxLogger.audio.info("MicrophoneTap: captura pausada (mic mutado)")
    }

    /// Retoma o envio de buffers ao stream.
    public func resumeCapture() {
        pauseLock.lock()
        capturePaused = false
        pauseLock.unlock()
        TxLogger.audio.info("MicrophoneTap: captura retomada (mic ativo)")
    }

    public func stop() {
        isRunning = false
        pauseLock.lock()
        capturePaused = false
        pauseLock.unlock()
        if tapInstalled {
            mixer.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        continuation?.finish()
        TxLogger.audio.info("MicrophoneTap stopped")
    }
}
