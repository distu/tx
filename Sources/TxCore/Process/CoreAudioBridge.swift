import Foundation
import CoreAudio
import AudioToolbox

/// Low-level bridge para Core Audio HAL.
/// Baseado em padrões públicos de AudioCap (Guilherme Rambo, BSD-2) e AudioTee (MIT).
public enum CoreAudioBridge {

    // MARK: - Property helpers

    public static func propertySize(
        object: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) throws -> UInt32 {
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else {
            throw TxError.coreAudioFailure(status, "AudioObjectGetPropertyDataSize")
        }
        return size
    }

    public static func getProperty<T>(
        object: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        defaultValue: T
    ) throws -> T {
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw TxError.coreAudioFailure(status, "AudioObjectGetPropertyData(\(address.mSelector))")
        }
        return value
    }

    public static func getPropertyArray<T>(
        object: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        type: T.Type
    ) throws -> [T] {
        var size = try propertySize(object: object, address: &address)
        let count = Int(size) / MemoryLayout<T>.size
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer)
        guard status == noErr else {
            throw TxError.coreAudioFailure(status, "AudioObjectGetPropertyData(array)")
        }
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    // MARK: - Process enumeration

    /// Retorna todos os `AudioObjectID` de processos do sistema (macOS 14.2+).
    public static func listProcessObjects() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return try getPropertyArray(
            object: AudioObjectID(kAudioObjectSystemObject),
            address: &address,
            type: AudioObjectID.self
        )
    }

    /// Traduz PID → `AudioObjectID` de processo (macOS 14.2+).
    public static func translatePidToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidVar = pid
        var objectID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidVar,
            &size,
            &objectID
        )
        guard status == noErr else {
            throw TxError.coreAudioFailure(status, "TranslatePIDToProcessObject")
        }
        return objectID
    }

    /// PID de um objeto de processo Core Audio.
    public static func pid(for processObject: AudioObjectID) throws -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return try getProperty(object: processObject, address: &address, defaultValue: pid_t(0))
    }

    /// Indica se o processo está reproduzindo áudio no momento.
    public static func isRunning(processObject: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    /// Indica se o processo tem input ativo (nós geralmente queremos apenas output).
    public static func isRunningInput(processObject: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    /// Indica se o processo tem output ativo (o que queremos tap).
    public static func isRunningOutput(processObject: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    /// Bundle ID do processo de áudio (quando disponível).
    public static func bundleID(for processObject: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(processObject, &address, 0, nil, &size) == noErr else {
            return nil
        }
        var bundleID: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &bundleID)
        guard status == noErr else { return nil }
        return bundleID as String
    }

}
