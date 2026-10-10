import Foundation

/// Wrapper sobre `UserDefaults` para as preferências de ditado.
public struct DictationSettings: Sendable {
    public var holdThresholdMs: Int
    public var doubleTapWindowMs: Int
    public var pasteWaitAfterSetMs: Int
    public var pasteWaitBeforeRestoreMs: Int
    public var preserveClipboard: Bool
    public var saveAudio: Bool
    public var language: String
    public var minDurationMs: Int

    public static let `default` = DictationSettings(
        holdThresholdMs: 200,
        doubleTapWindowMs: 300,
        pasteWaitAfterSetMs: 30,
        pasteWaitBeforeRestoreMs: 200,
        preserveClipboard: true,
        saveAudio: false,
        language: "pt",
        minDurationMs: 500
    )

    private static let keyPrefix = "tx.dictation."

    public static func load() -> DictationSettings {
        let ud = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int {
            let v = ud.integer(forKey: keyPrefix + key)
            return v == 0 ? fallback : v
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            ud.object(forKey: keyPrefix + key) == nil ? fallback : ud.bool(forKey: keyPrefix + key)
        }
        func str(_ key: String, _ fallback: String) -> String {
            ud.string(forKey: keyPrefix + key) ?? fallback
        }
        return DictationSettings(
            holdThresholdMs: int("holdThresholdMs", 200),
            doubleTapWindowMs: int("doubleTapWindowMs", 300),
            pasteWaitAfterSetMs: int("pasteWaitAfterSetMs", 30),
            pasteWaitBeforeRestoreMs: int("pasteWaitBeforeRestoreMs", 200),
            preserveClipboard: bool("preserveClipboard", true),
            saveAudio: bool("saveAudio", false),
            language: str("language", "pt"),
            minDurationMs: int("minDurationMs", 500)
        )
    }

    public func save() {
        let ud = UserDefaults.standard
        ud.set(holdThresholdMs, forKey: Self.keyPrefix + "holdThresholdMs")
        ud.set(doubleTapWindowMs, forKey: Self.keyPrefix + "doubleTapWindowMs")
        ud.set(pasteWaitAfterSetMs, forKey: Self.keyPrefix + "pasteWaitAfterSetMs")
        ud.set(pasteWaitBeforeRestoreMs, forKey: Self.keyPrefix + "pasteWaitBeforeRestoreMs")
        ud.set(preserveClipboard, forKey: Self.keyPrefix + "preserveClipboard")
        ud.set(saveAudio, forKey: Self.keyPrefix + "saveAudio")
        ud.set(language, forKey: Self.keyPrefix + "language")
        ud.set(minDurationMs, forKey: Self.keyPrefix + "minDurationMs")
    }
}
