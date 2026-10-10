import Foundation

/// The interface preference is independent of the language used to transcribe audio.
public enum InterfaceLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case portugueseBrazil = "pt-BR"

    public static let preferenceKey = "tx.interface.language"

    public static func resolved(
        preference: InterfaceLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages,
        regionCode: String? = Locale.current.region?.identifier
    ) -> InterfaceLanguage {
        guard preference == .system else { return preference }
        let first = preferredLanguages.first?.replacingOccurrences(of: "_", with: "-").lowercased() ?? ""
        if first == "pt-br" || (first == "pt" && regionCode?.uppercased() == "BR") {
            return .portugueseBrazil
        }
        return .english
    }

    public var locale: Locale {
        Locale(identifier: self == .portugueseBrazil ? "pt-BR" : "en")
    }
}
