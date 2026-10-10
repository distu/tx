import Foundation
#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// Lê título da janela frontal de um processo via Accessibility API.
/// Vantagem: exige apenas permissão de Accessibility, não de Screen Recording.
public enum AXWindowReader {

    public static func isAccessibilityEnabled() -> Bool {
        #if canImport(ApplicationServices)
        return AXIsProcessTrusted()
        #else
        return false
        #endif
    }

    public static func requestAccessibilityPrompt() {
        #if canImport(ApplicationServices)
        let options: [String: Any] = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        #endif
    }

    public static func frontWindowTitle(pid: pid_t) -> String? {
        #if canImport(ApplicationServices)
        let app = AXUIElementCreateApplication(pid)
        var windows: AnyObject?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        guard status == .success, let windowArray = windows as? [AXUIElement], !windowArray.isEmpty else {
            return nil
        }
        for window in windowArray {
            var title: AnyObject?
            let titleStatus = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            if titleStatus == .success, let str = title as? String, !str.isEmpty {
                return str
            }
        }
        return nil
        #else
        return nil
        #endif
    }
}
