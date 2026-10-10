import ApplicationServices
import Foundation

/// Lê o controle do próprio microfone no Meet pela árvore de acessibilidade
/// do navegador. Não altera foco, abas nem o estado do botão.
public enum MeetAccessibilityReader {
    public static var isAvailable: Bool { AXIsProcessTrusted() }

    /// Retorna nil quando não há associação única com uma chamada ativa ou
    /// quando o controle local não pode ser identificado.
    public static func micMuted(browserPID: pid_t, meetingURL: URL) -> Bool? {
        guard isAvailable,
              browserPID > 1,
              AppleScriptBridge.isRoomURL(meetingURL) ||
                AppleScriptBridge.isTeamsURL(meetingURL) else { return nil }

        if AppleScriptBridge.isTeamsURL(meetingURL) {
            return teamsMicMuted(processPID: browserPID)
        }
        let targetRoom = roomCode(in: meetingURL.absoluteString)
        guard let targetRoom else { return nil }

        let app = AXUIElementCreateApplication(browserPID)
        guard let windows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
            return nil
        }

        var visibleMeetRooms = Set<String>()
        var matchingStates: [Bool] = []
        for window in windows.prefix(20) {
            let snapshot = scan(window)
            visibleMeetRooms.formUnion(snapshot.rooms)
            if snapshot.rooms.contains(targetRoom), snapshot.rooms.count == 1,
               snapshot.micStates.count == 1 {
                matchingStates.append(snapshot.micStates[0])
            }
        }
        guard visibleMeetRooms == [targetRoom], matchingStates.count == 1 else { return nil }
        return matchingStates[0]
    }

    /// Teams pode abrir uma chamada sem URL de sala. Exige uma única janela
    /// com página Teams, botão de saída da chamada e botão local de mic.
    public static func teamsMicMuted(processPID: pid_t, nativeApp: Bool = false) -> Bool? {
        guard isAvailable, processPID > 1 else { return nil }
        let app = AXUIElementCreateApplication(processPID)
        guard let windows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
            return nil
        }
        var states: [Bool] = []
        for window in windows.prefix(20) {
            let snapshot = scan(window)
            if (nativeApp || snapshot.hasTeamsPage), snapshot.hasLeaveCall,
               snapshot.micStates.count == 1 {
                states.append(snapshot.micStates[0])
            }
        }
        return states.count == 1 ? states[0] : nil
    }

    static func roomCode(in raw: String) -> String? {
        let candidate = raw.hasPrefix("https://") ? raw : "https://\(raw)"
        guard let url = URL(string: candidate), AppleScriptBridge.isRoomURL(url) else { return nil }
        return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func localMicMuted(label raw: String) -> Bool? {
        let label = normalized(raw)
        if label.hasPrefix("desativar mudo do microfone") { return true }
        if label.hasPrefix("ativar mudo do microfone") { return false }
        if label.hasPrefix("ativar microfone") || label.hasPrefix("ligar microfone") ||
           label.hasPrefix("turn on microphone") || label.hasPrefix("unmute microphone") ||
           label.hasPrefix("activar micrófono") || label == "ativar som" ||
           label.hasPrefix("ativar som (") ||
           label.hasPrefix("unmute mic") || label == "unmute" {
            return true
        }
        if label.hasPrefix("desativar microfone") || label.hasPrefix("desligar microfone") ||
           label.hasPrefix("turn off microphone") || label.hasPrefix("mute microphone") ||
           label.hasPrefix("desactivar micrófono") || label == "desativar som" ||
           label.hasPrefix("desativar som (") ||
           label.hasPrefix("mute mic") || label == "mute" {
            return false
        }
        return nil
    }

    static func isLeaveCallButton(_ raw: String) -> Bool {
        let label = normalized(raw)
        return label == "sair" || label.hasPrefix("sair da chamada") || label.hasPrefix("sair da reunião") ||
            label.hasPrefix("desligar") || label.hasPrefix("leave call") ||
            label.hasPrefix("leave meeting") || label.hasPrefix("hang up")
    }

    private static func normalized(_ raw: String) -> String {
        raw.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func isBrowserAddressBar(label raw: String) -> Bool {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return label == "barra de endereço e de pesquisa" ||
            label == "address and search bar" ||
            label == "barra de direcciones y de búsqueda"
    }

    private struct WindowSnapshot {
        var rooms = Set<String>()
        var micStates: [Bool] = []
        var hasTeamsPage = false
        var hasLeaveCall = false
    }

    private static func scan(_ window: AXUIElement) -> WindowSnapshot {
        var result = WindowSnapshot()
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var cursor = 0
        while cursor < queue.count && cursor < 10_000 {
            let (element, depth) = queue[cursor]
            cursor += 1
            guard let role = attribute(element, kAXRoleAttribute as CFString) as? String else {
                continue
            }

            if role == "AXWebArea",
               let rawURL = (attribute(element, kAXURLAttribute as CFString) as? URL)?.absoluteString ??
                    (attribute(element, kAXURLAttribute as CFString) as? String),
               let url = URL(string: rawURL) {
                if let room = roomCode(in: rawURL) { result.rooms.insert(room) }
                if AppleScriptBridge.isTeamsURL(url) { result.hasTeamsPage = true }
            }

            if role == kAXTextFieldRole as String,
               let label = nonEmptyLabel(element),
               isBrowserAddressBar(label: label),
               let value = attribute(element, kAXValueAttribute as CFString) as? String {
                if let room = roomCode(in: value) { result.rooms.insert(room) }
                if let url = URL(string: value), AppleScriptBridge.isTeamsURL(url) {
                    result.hasTeamsPage = true
                }
            } else if role == kAXButtonRole as String {
                let label = nonEmptyLabel(element) ?? ""
                if let muted = localMicMuted(label: label) {
                    result.micStates.append(muted)
                }
                if isLeaveCallButton(label) { result.hasLeaveCall = true }
            }

            if depth < 80,
               let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return result
    }

    private static func attribute(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else { return nil }
        return value
    }

    private static func nonEmptyLabel(_ element: AXUIElement) -> String? {
        let title = attribute(element, kAXTitleAttribute as CFString) as? String
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        let description = attribute(element, kAXDescriptionAttribute as CFString) as? String
        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }
        return nil
    }
}
