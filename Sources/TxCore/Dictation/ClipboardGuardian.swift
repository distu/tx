import Foundation
import AppKit

/// Snapshot de todo o conteúdo atual do `NSPasteboard`. Preserva múltiplos itens
/// e todos os tipos representados, permitindo restauração fiel após o paste.
public struct PasteboardSnapshot: Sendable {
    public let items: [[String: Data]]

    public static func capture(_ pb: NSPasteboard = .general) -> PasteboardSnapshot {
        let raw = pb.pasteboardItems ?? []
        let snapshot = raw.map { item -> [String: Data] in
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            return dict
        }
        return PasteboardSnapshot(items: snapshot)
    }

    public func restore(to pb: NSPasteboard = .general) {
        pb.clearContents()
        let newItems = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (rawType, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        pb.writeObjects(newItems)
    }
}

/// Orquestra o ciclo "preservar -> colar -> restaurar" do clipboard.
@MainActor
public final class ClipboardGuardian {
    public static let shared = ClipboardGuardian()

    public struct Timings: Sendable {
        public var waitAfterSetMs: Int
        public var waitBeforeRestoreMs: Int
        public init(waitAfterSetMs: Int = 30, waitBeforeRestoreMs: Int = 200) {
            self.waitAfterSetMs = waitAfterSetMs
            self.waitBeforeRestoreMs = waitBeforeRestoreMs
        }
    }

    public var timings: Timings = Timings()
    public var preserveEnabled: Bool = true

    private init() {}

    /// Preserva clipboard, escreve `text`, sintetiza Cmd+V, aguarda o alvo consumir
    /// e restaura o snapshot. No-op gracioso se Accessibility não estiver concedida.
    public func pasteText(_ text: String) async throws {
        let snapshot = preserveEnabled ? PasteboardSnapshot.capture() : nil

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        try? await Task.sleep(for: .milliseconds(timings.waitAfterSetMs))

        try PasteSimulator.sendCommandV()

        try? await Task.sleep(for: .milliseconds(timings.waitBeforeRestoreMs))

        if let snapshot {
            snapshot.restore()
        }
    }
}
