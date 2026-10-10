import XCTest
@testable import TxCore

final class InterfaceLanguageTests: XCTestCase {
    func testBrazilianPortuguesePrimaryLanguageUsesPortuguese() {
        XCTAssertEqual(
            InterfaceLanguage.resolved(preference: .system, preferredLanguages: ["pt-BR", "en-US"], regionCode: "BR"),
            .portugueseBrazil
        )
        XCTAssertEqual(
            InterfaceLanguage.resolved(preference: .system, preferredLanguages: ["pt_BR"], regionCode: "US"),
            .portugueseBrazil
        )
    }

    func testOtherPrimaryLanguagesUseEnglish() {
        XCTAssertEqual(
            InterfaceLanguage.resolved(preference: .system, preferredLanguages: ["en-US", "pt-BR"], regionCode: "BR"),
            .english
        )
        XCTAssertEqual(
            InterfaceLanguage.resolved(preference: .system, preferredLanguages: ["pt-PT"], regionCode: "PT"),
            .english
        )
    }

    func testManualSelectionOverridesSystem() {
        XCTAssertEqual(
            InterfaceLanguage.resolved(preference: .english, preferredLanguages: ["pt-BR"], regionCode: "BR"),
            .english
        )
        XCTAssertEqual(
            InterfaceLanguage.resolved(preference: .portugueseBrazil, preferredLanguages: ["en-US"], regionCode: "US"),
            .portugueseBrazil
        )
    }
}
