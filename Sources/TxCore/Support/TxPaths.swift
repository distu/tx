import Foundation

public enum TxPaths {
    public static let applicationSupportDirName = "tx"

    public static var applicationSupport: URL {
        #if DEBUG
        if Bundle.main.bundleIdentifier == "dev.distuai.tx.demo" {
            let dir = URL(fileURLWithPath: "/private/tmp/tx-demo-screenshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        if let testPath = ProcessInfo.processInfo.environment["TX_TEST_APPLICATION_SUPPORT"],
           testPath.hasPrefix("/") {
            let dir = URL(fileURLWithPath: testPath, isDirectory: true).standardizedFileURL
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(applicationSupportDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(applicationSupportDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var databaseURL: URL {
        applicationSupport.appendingPathComponent("tx.sqlite", isDirectory: false)
    }

    public static var recordingsRoot: URL {
        let url = applicationSupport.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var chromeProfilesRoot: URL {
        let url = applicationSupport.appendingPathComponent("chrome-profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var whisperCacheRoot: URL {
        let url = caches.appendingPathComponent("whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var dictationsRoot: URL {
        let url = applicationSupport.appendingPathComponent("dictations", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func dictationAudioURL(id: UUID, startedAt: Date = .now) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let day = formatter.string(from: startedAt)
        let dir = dictationsRoot.appendingPathComponent(day, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id.uuidString).m4a", isDirectory: false)
    }

    public static func sessionDirectory(sessionId: UUID, startedAt: Date = .now) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let day = formatter.string(from: startedAt)
        let dir = recordingsRoot
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent(sessionId.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func chromeProfileDirectory(profileId: UUID) -> URL {
        chromeProfilesRoot.appendingPathComponent(profileId.uuidString, isDirectory: true)
    }
}
