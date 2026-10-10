import Foundation

public enum DictationState: Equatable, Sendable {
    case idle
    case recording(mode: Dictation.Mode, startedAt: Date)
    case transcribing(durationMs: Int)
    case pasting(text: String)
    case error(String)

    public var isActive: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}
