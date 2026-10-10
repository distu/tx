import Foundation
import Observation

@Observable
@MainActor
public final class ChromeProfileLauncher {
    public static let chromeAppPath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    public static let chromeBundleId = "com.google.Chrome"

    public private(set) var profiles: [ChromeProfile] = []
    public private(set) var runningPids: [UUID: pid_t] = [:]

    private let repository: ChromeProfileRepository
    private let runningProcesses: NSMapTable<NSNumber, Process> = .strongToStrongObjects()

    public init(repository: ChromeProfileRepository) {
        self.repository = repository
        reload()
    }

    public func reload() {
        do {
            profiles = try repository.all()
        } catch {
            TxLogger.chrome.error("Failed to load profiles: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func createProfile(name: String, projectId: UUID?, color: String?) throws -> ChromeProfile {
        let profile = ChromeProfile(
            name: name,
            userDataDir: TxPaths.chromeProfileDirectory(profileId: UUID()),
            projectId: projectId,
            color: color
        )
        try FileManager.default.createDirectory(at: profile.userDataDir, withIntermediateDirectories: true)
        try repository.insert(profile)
        reload()
        return profile
    }

    public func launch(_ profile: ChromeProfile) throws -> pid_t {
        guard FileManager.default.fileExists(atPath: Self.chromeAppPath) else {
            throw TxError.invalidState("Google Chrome não encontrado em /Applications")
        }

        try FileManager.default.createDirectory(at: profile.userDataDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.chromeAppPath)
        process.arguments = [
            "--user-data-dir=\(profile.userDataDir.path)",
            "--no-first-run",
            "--no-default-browser-check",
        ]
        try process.run()

        let pid = process.processIdentifier
        runningPids[profile.id] = pid
        runningProcesses.setObject(process, forKey: NSNumber(value: pid))

        TxLogger.chrome.info("Launched Chrome profile '\(profile.name, privacy: .public)' pid=\(pid)")
        return pid
    }

    public func delete(_ profile: ChromeProfile) throws {
        if let pid = runningPids[profile.id] {
            killProcess(pid: pid)
            runningPids.removeValue(forKey: profile.id)
        }

        if FileManager.default.fileExists(atPath: profile.userDataDir.path) {
            try FileManager.default.removeItem(at: profile.userDataDir)
        }
        try repository.delete(id: profile.id)
        reload()
    }

    public func resolveProfile(forPid pid: pid_t) -> ChromeProfile? {
        if let (profileId, _) = runningPids.first(where: { $0.value == pid }),
           let profile = profiles.first(where: { $0.id == profileId }) {
            return profile
        }

        guard let userDataDir = ProcessArgsReader.userDataDir(for: pid) else { return nil }
        return profiles.first { $0.userDataDir.path == userDataDir }
    }

    private func killProcess(pid: pid_t) {
        if let process = runningProcesses.object(forKey: NSNumber(value: pid)) {
            process.terminate()
            runningProcesses.removeObject(forKey: NSNumber(value: pid))
        } else {
            kill(pid, SIGTERM)
        }
    }
}
