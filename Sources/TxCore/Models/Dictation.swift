import Foundation

/// Uma entrada de ditado global. Representa uma gravação do microfone
/// iniciada pelo atalho Fn, transcrita localmente e colada no app em foco.
public struct Dictation: Identifiable, Sendable, Hashable {
    public enum Mode: String, Sendable {
        case pushToTalk = "ptt"
        case locked = "locked"
    }

    public let id: UUID
    public var startedAt: Date
    public var durationMs: Int
    public var wordCount: Int
    public var wpm: Double
    public var text: String
    public var mode: Mode
    public var targetApp: String?
    public var targetBundle: String?
    public var pasted: Bool
    public var canceled: Bool
    public var audioPath: URL?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        durationMs: Int,
        wordCount: Int,
        wpm: Double,
        text: String,
        mode: Mode,
        targetApp: String? = nil,
        targetBundle: String? = nil,
        pasted: Bool = true,
        canceled: Bool = false,
        audioPath: URL? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.wordCount = wordCount
        self.wpm = wpm
        self.text = text
        self.mode = mode
        self.targetApp = targetApp
        self.targetBundle = targetBundle
        self.pasted = pasted
        self.canceled = canceled
        self.audioPath = audioPath
        self.createdAt = createdAt
    }

    public static func computeWordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    public static func computeWpm(words: Int, durationMs: Int) -> Double {
        guard durationMs > 0 else { return 0 }
        let minutes = Double(durationMs) / 60_000.0
        return Double(words) / minutes
    }
}
