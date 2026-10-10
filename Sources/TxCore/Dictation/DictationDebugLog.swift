import Foundation
import Observation

public enum DictationLogLevel: String, Sendable {
    case info
    case warn
    case error
    case success
}

public struct DictationLogEntry: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let timestamp: Date
    public let level: DictationLogLevel
    public let category: String
    public let message: String

    public init(timestamp: Date = .now, level: DictationLogLevel, category: String, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

/// Buffer circular thread-safe com as últimas N entradas do pipeline de ditado.
/// Espelha no console via `TxLogger.app` e em tempo real na janela Debug.
@Observable
@MainActor
public final class DictationDebugLog {
    public static let shared = DictationDebugLog()

    public private(set) var entries: [DictationLogEntry] = []
    public var maxEntries: Int = 400

    private init() {}

    public func info(_ category: String, _ message: String) {
        push(level: .info, category: category, message: message)
    }
    public func success(_ category: String, _ message: String) {
        push(level: .success, category: category, message: message)
    }
    public func warn(_ category: String, _ message: String) {
        push(level: .warn, category: category, message: message)
    }
    public func error(_ category: String, _ message: String) {
        push(level: .error, category: category, message: message)
    }

    public func clear() { entries.removeAll() }

    private func push(level: DictationLogLevel, category: String, message: String) {
        let entry = DictationLogEntry(level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        switch level {
        case .info, .success:
            TxLogger.app.info("[dict.\(category, privacy: .public)] \(message, privacy: .public)")
        case .warn:
            TxLogger.app.warning("[dict.\(category, privacy: .public)] \(message, privacy: .public)")
        case .error:
            TxLogger.app.error("[dict.\(category, privacy: .public)] \(message, privacy: .public)")
        }
    }
}

/// Helper nonisolated para ser chamado de contextos não-main (ex: callback do
/// CGEventTap). Despacha o enfileiramento para o main actor.
public enum DictDbg {
    public static func info(_ category: String, _ message: String) {
        Task { @MainActor in DictationDebugLog.shared.info(category, message) }
    }
    public static func success(_ category: String, _ message: String) {
        Task { @MainActor in DictationDebugLog.shared.success(category, message) }
    }
    public static func warn(_ category: String, _ message: String) {
        Task { @MainActor in DictationDebugLog.shared.warn(category, message) }
    }
    public static func error(_ category: String, _ message: String) {
        Task { @MainActor in DictationDebugLog.shared.error(category, message) }
    }
}
