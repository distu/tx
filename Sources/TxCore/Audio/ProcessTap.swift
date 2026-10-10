import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Logger de diagnóstico que escreve direto em arquivo (bypass stdout/stderr/OSLog).
public func dbg(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    let url = URL(fileURLWithPath: "/tmp/tx-debug.log")
    if let fh = try? FileHandle(forWritingTo: url) {
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8))
    }
}

/// Cria um Core Audio Tap para capturar o áudio de saída de um ou mais PIDs e
/// expõe os buffers PCM via `AsyncStream<AVAudioPCMBuffer>`.
///
/// Estratégia (macOS 14.4+):
/// 1. `AudioHardwareCreateProcessTap` com `CATapDescription` apontando para os processos.
/// 2. Cria um aggregate device privado que usa o tap como sub-device input.
/// 3. Instala um IOProc no aggregate device para receber callbacks de áudio.
/// 4. Cada callback converte o `AudioBufferList` em `AVAudioPCMBuffer` e publica no stream.
///
/// Aceitar múltiplos PIDs é importante para Chrome/Electron, onde diferentes Helper processes
/// podem lidar com áudio de abas distintas (ex: Meet usa processo diferente do Renderer).
///
/// Baseado em padrões públicos do AudioCap (Guilherme Rambo, BSD-2).
public final class ProcessTap: @unchecked Sendable {
    /// PID principal (identificador da sessão; o primeiro da lista).
    public let pid: pid_t
    /// Todos os PIDs que serão incluídos no tap (mixdown estéreo).
    public let pids: [pid_t]

    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapStreamDescription: AudioStreamBasicDescription?
    private var format: AVAudioFormat?

    private var continuation: AsyncStream<AudioBufferBox>.Continuation?
    public let stream: AsyncStream<AudioBufferBox>

    public private(set) var isRunning: Bool = false

    public init(pids: [pid_t]) {
        self.pids = pids
        self.pid = pids.first ?? 0
        var cont: AsyncStream<AudioBufferBox>.Continuation!
        self.stream = AsyncStream { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    /// Conveniência para capturar um único processo.
    public convenience init(pid: pid_t) {
        self.init(pids: [pid])
    }

    deinit {
        try? stop()
        continuation?.finish()
    }

    public func start() throws {
        guard !isRunning else { return }
        do {
            try startResources()
        } catch {
            try? stop()
            throw error
        }
    }

    private func startResources() throws {

        dbg("[tap] start() pids=\(pids)")

        // 1. Criar o tap.
        try createTap()
        dbg("[tap] createTap OK tapID=\(tapID)")

        // 2. Descobrir stream description do tap.
        try fetchTapFormat()
        dbg("[tap] fetchTapFormat OK: \(format?.description ?? "nil")")

        // 3. Criar aggregate device privado que usa o tap.
        try createAggregateDevice()
        dbg("[tap] createAggregateDevice OK id=\(aggregateDeviceID)")

        // 4. Instalar IO Proc para receber buffers.
        try installIOProc()
        dbg("[tap] installIOProc OK")

        // 5. Iniciar o device.
        let status = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard status == noErr else {
            dbg("[tap] AudioDeviceStart FAILED status=\(status)")
            throw TxError.coreAudioFailure(status, "AudioDeviceStart")
        }

        isRunning = true
        dbg("[tap] RUNNING for PID \(pid)")
    }

    public func stop() throws {
        let wasRunning = isRunning
        isRunning = false

        if let deviceProcID {
            if wasRunning { AudioDeviceStop(aggregateDeviceID, deviceProcID) }
            AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
            self.deviceProcID = nil
        }

        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }

        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }

        continuation?.finish()
        TxLogger.audio.info("ProcessTap stopped for PID \(self.pid)")
    }

    // MARK: - Private

    private func createTap() throws {
        // Traduz todos os PIDs para AudioObjectIDs.
        var processObjects: [AudioObjectID] = []
        for p in pids {
            guard let obj = try? CoreAudioBridge.translatePidToProcessObject(p), obj != 0 else {
                dbg("[tap] PID \(p) NAO encontrado no CoreAudio")
                continue
            }
            let isOut = CoreAudioBridge.isRunningOutput(processObject: obj)
            let bid = CoreAudioBridge.bundleID(for: obj) ?? "<nil>"
            dbg("[tap] PID \(p) -> obj=\(obj) isRunningOutput=\(isOut) bundle=\(bid)")
            processObjects.append(obj)
        }

        guard !processObjects.isEmpty else {
            throw TxError.invalidState("Nenhum processo válido encontrado para criar tap (pids=\(pids))")
        }

        TxLogger.audio.info("ProcessTap: criando tap com \(processObjects.count) processo(s)")

        // ATENÇÃO: `isExclusive = true` inverte o sentido — passa a capturar TODOS
        // os processos EXCETO os listados (ver CATapDescription.h). Para capturar
        // apenas o(s) processo(s)-alvo, isExclusive DEVE ser false.
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjects)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true
        tapDescription.isExclusive = false

        var tapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else {
            throw TxError.coreAudioFailure(status, "AudioHardwareCreateProcessTap")
        }
        self.tapID = tapID
        TxLogger.audio.info("ProcessTap: tapID \(tapID) criado para \(processObjects.count) processo(s)")
    }

    private func fetchTapFormat() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw TxError.coreAudioFailure(status, "AudioObjectGetPropertyData(kAudioTapPropertyFormat)")
        }
        self.tapStreamDescription = asbd

        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TxError.audioEngineFailure("Falha criando AVAudioFormat do tap")
        }
        self.format = format
    }

    private func createAggregateDevice() throws {
        // Precisamos do UID do tap para referenciá-lo no aggregate.
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var tapUID: CFString = "" as CFString
        let uidStatus = AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, &tapUID)
        guard uidStatus == noErr else {
            throw TxError.coreAudioFailure(uidStatus, "kAudioTapPropertyUID")
        }

        let aggregateUID = "dev.distuai.tx.aggregate.\(pid).\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "tx-aggregate-\(pid)",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: tapUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ] as [String: Any]
            ]
        ]

        var deviceID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr else {
            throw TxError.coreAudioFailure(status, "AudioHardwareCreateAggregateDevice")
        }
        self.aggregateDeviceID = deviceID
    }

    private func installIOProc() throws {
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(
            aggregateDeviceID,
            { _, _, inInputData, _, _, _, clientData in
                guard let clientData else { return noErr }
                let tap = Unmanaged<ProcessTap>.fromOpaque(clientData).takeUnretainedValue()
                tap.handleInputBuffer(inInputData)
                return noErr
            },
            selfPointer,
            &procID
        )

        guard status == noErr, let procID else {
            throw TxError.coreAudioFailure(status, "AudioDeviceCreateIOProcID")
        }
        self.deviceProcID = procID
    }

    private var bufferCount = 0

    private func handleInputBuffer(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let format else { return }
        bufferCount += 1
        if bufferCount <= 5 || bufferCount % 500 == 0 {
            dbg("[tap] buffer #\(bufferCount)")
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let firstBuffer = bufferList.first else { return }
        let frames = AVAudioFrameCount(firstBuffer.mDataByteSize) / format.streamDescription.pointee.mBytesPerFrame

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcmBuffer.frameLength = frames

        // Copia os dados do AudioBufferList para o PCMBuffer.
        if let dstBufferList = pcmBuffer.audioBufferList as UnsafePointer<AudioBufferList>? {
            let dstMutable = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: dstBufferList))
            for i in 0..<min(dstMutable.count, bufferList.count) {
                let src = bufferList[i]
                var dst = dstMutable[i]
                if let srcData = src.mData, let dstData = dst.mData {
                    let bytesToCopy = min(src.mDataByteSize, dst.mDataByteSize)
                    memcpy(dstData, srcData, Int(bytesToCopy))
                    dst.mDataByteSize = bytesToCopy
                    dstMutable[i] = dst
                }
            }
        }

        continuation?.yield(AudioBufferBox(pcmBuffer))
    }
}
