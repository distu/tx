import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

public enum PasteSimulator {
    /// Código virtual da tecla "V" (layout físico US/ANSI). O CGEvent usa códigos
    /// físicos — o layout do usuário é irrelevante.
    private static let kVK_ANSI_V: CGKeyCode = 0x09

    /// Sintetiza Cmd+V no app em foco via `CGEvent.post(tap: .cgAnnotatedSessionEventTap)`.
    /// Exige permissão Accessibility. Lança `TxError.permissionDenied("Accessibility")`
    /// se o usuário não concedeu.
    public static func sendCommandV() throws {
        guard hasAccessibilityPermission() else {
            throw TxError.permissionDenied("Accessibility")
        }

        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source,
                                    virtualKey: kVK_ANSI_V,
                                    keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: kVK_ANSI_V,
                                  keyDown: false) else {
            throw TxError.invalidState("Falha ao criar CGEvent keyboard Cmd+V")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }

    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Dispara o prompt TCC de Accessibility (uma vez por app).
    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options: NSDictionary = [key: true]
        return AXIsProcessTrustedWithOptions(options)
    }
}
