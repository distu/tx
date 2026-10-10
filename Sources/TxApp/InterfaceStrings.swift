import Foundation
import TxCore

/// For strings assembled at runtime; SwiftUI localizes literal Text/Label keys itself.
enum InterfaceStrings {
    static var language: InterfaceLanguage {
        let raw = UserDefaults.standard.string(forKey: InterfaceLanguage.preferenceKey) ?? InterfaceLanguage.system.rawValue
        return InterfaceLanguage.resolved(preference: InterfaceLanguage(rawValue: raw) ?? .system)
    }

    static func text(_ key: String) -> String {
        let locale = language.rawValue
        guard let path = Bundle.main.path(forResource: locale, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        let value = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        if value != key { return value }
        for prefix in ["Microfone indisponível: ", "Falha buscando ditado: ", "Retry falhou: ", "arquivo não existe: ", "falhou: "] where key.hasPrefix(prefix) {
            let translated = bundle.localizedString(forKey: prefix, value: prefix, table: "Localizable")
            return translated + key.dropFirst(prefix.count)
        }
        return key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: language.locale, arguments: arguments)
    }

    static func date(_ value: Date, time: Date.FormatStyle.TimeStyle = .shortened) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: time).locale(language.locale))
    }
}
