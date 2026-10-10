import Foundation
import Security

/// Keeps the optional Gemini API key in the macOS Keychain.
/// Existing installs are migrated from the former UserDefaults entry on first read.
public enum GeminiCredentialStore {
    private static let service = "dev.distuai.tx.gemini"
    private static let account = "api-key"
    private static let legacyPreference = "tx.gemini.apiKey"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public static func load() -> String {
        var readQuery = query
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        readQuery[kSecReturnData as String] = true
        var result: CFTypeRef?
        if SecItemCopyMatching(readQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }

        guard let oldKey = UserDefaults.standard.string(forKey: legacyPreference),
              !oldKey.isEmpty else { return "" }
        _ = save(oldKey)
        return oldKey
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { return false }
            UserDefaults.standard.removeObject(forKey: legacyPreference)
            return true
        }

        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        UserDefaults.standard.removeObject(forKey: legacyPreference)
        return true
    }
}
