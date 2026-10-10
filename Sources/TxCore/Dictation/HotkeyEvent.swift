import Foundation

public enum HotkeyEvent: Sendable, Equatable {
    case holdStarted(timestamp: TimeInterval)
    case holdEnded(timestamp: TimeInterval)
    case doubleTap(timestamp: TimeInterval)
    case escapePressed
}

public enum DictationPermission: String, Sendable {
    case granted
    case denied
    case notDetermined
}
