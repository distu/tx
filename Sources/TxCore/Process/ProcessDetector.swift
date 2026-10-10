import Foundation
import CoreAudio
#if canImport(AppKit)
import AppKit
#endif

public actor ProcessDetector {
    public init() {}

    /// Lista todos os processos que estão produzindo áudio de saída no momento.
    public func listAudioActiveProcesses() async -> [AudioProcess] {
        do {
            let processObjects = try CoreAudioBridge.listProcessObjects()
            var processes: [AudioProcess] = []
            var seenRoots: Set<pid_t> = []

            for processObject in processObjects {
                guard CoreAudioBridge.isRunningOutput(processObject: processObject) else { continue }

                let pid: pid_t
                do {
                    pid = try CoreAudioBridge.pid(for: processObject)
                } catch {
                    continue
                }

                guard pid > 0 else { continue }
                let bundleId = CoreAudioBridge.bundleID(for: processObject)
                let root = ProcessArgsReader.captureGroupRoot(for: pid, bundleId: bundleId) ?? pid
                guard seenRoots.insert(root).inserted else { continue }

                let (name, iconData) = processMetadata(pid: root, bundleId: bundleId)
                let userDataDir = ProcessArgsReader.userDataDir(for: root)

                processes.append(AudioProcess(
                    pid: pid,
                    name: name,
                    bundleId: bundleId,
                    userDataDir: userDataDir,
                    iconData: iconData
                ))
            }

            return processes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            TxLogger.process.error("Failed to list audio processes: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public func resolveUserDataDir(for pid: pid_t) -> String? {
        ProcessArgsReader.userDataDir(for: pid)
    }

    public func validateHasActiveOutput(pid: pid_t) async throws {
        let processObject = try CoreAudioBridge.translatePidToProcessObject(pid)
        guard CoreAudioBridge.isRunningOutput(processObject: processObject) else {
            throw TxError.processSilent(pid)
        }
    }

    // MARK: - Private

    private func processMetadata(pid: pid_t, bundleId: String?) -> (name: String, iconData: Data?) {
        #if canImport(AppKit)
        if let app = NSRunningApplication(processIdentifier: pid) {
            let name = app.localizedName ?? bundleId ?? "PID \(pid)"
            let iconData = app.icon?.tiffRepresentation
            return (name, iconData)
        }
        #endif
        return (bundleId ?? "PID \(pid)", nil)
    }
}
