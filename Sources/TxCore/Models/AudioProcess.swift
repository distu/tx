import Foundation
#if canImport(AppKit)
import AppKit
#endif

public struct AudioProcess: Identifiable, Sendable, Hashable {
    public let pid: pid_t
    public let name: String
    public let bundleId: String?
    public let userDataDir: String?
    public let iconData: Data?

    public var id: pid_t { pid }

    public init(
        pid: pid_t,
        name: String,
        bundleId: String? = nil,
        userDataDir: String? = nil,
        iconData: Data? = nil
    ) {
        self.pid = pid
        self.name = name
        self.bundleId = bundleId
        self.userDataDir = userDataDir
        self.iconData = iconData
    }

    #if canImport(AppKit)
    public var icon: NSImage? {
        guard let iconData else { return nil }
        return NSImage(data: iconData)
    }
    #endif
}

public struct AudioFiles: Sendable, Hashable {
    public let transcriptAudio: URL
    public let playbackAudio: URL
    public let appChannel: URL
    public let micChannel: URL

    public init(
        transcriptAudio: URL,
        playbackAudio: URL,
        appChannel: URL,
        micChannel: URL
    ) {
        self.transcriptAudio = transcriptAudio
        self.playbackAudio = playbackAudio
        self.appChannel = appChannel
        self.micChannel = micChannel
    }
}
