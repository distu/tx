import Foundation

/// Modelos Gemini disponíveis para usar tanto em transcrição quanto em
/// resumo/inteligência. O usuário escolhe nas Configurações; o app armazena
/// o `rawValue` em UserDefaults e monta a URL dinamicamente.
public enum GeminiModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case flash25 = "gemini-2.5-flash"
    case flashLite25 = "gemini-2.5-flash-lite"
    case pro25 = "gemini-2.5-pro"
    case flash20 = "gemini-2.0-flash"
    case flashLite20 = "gemini-2.0-flash-lite"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .flash25: return "Gemini 2.5 Flash (recomendado)"
        case .flashLite25: return "Gemini 2.5 Flash-Lite (mais barato)"
        case .pro25: return "Gemini 2.5 Pro (melhor qualidade)"
        case .flash20: return "Gemini 2.0 Flash"
        case .flashLite20: return "Gemini 2.0 Flash-Lite"
        }
    }

    public var costHint: String {
        switch self {
        case .flash25: return "$0.30 in / $2.50 out por 1M tokens"
        case .flashLite25: return "$0.10 in / $0.40 out por 1M tokens"
        case .pro25: return "$1.25 in / $10.00 out por 1M tokens"
        case .flash20: return "$0.10 in / $0.40 out por 1M tokens"
        case .flashLite20: return "$0.075 in / $0.30 out por 1M tokens"
        }
    }

    public static let intelligenceDefault: GeminiModel = .flash25
    public static let transcriptionDefault: GeminiModel = .flash25

    public static let intelligenceModelKey = "tx.gemini.intelligenceModel"
    public static let transcriptionModelKey = "tx.gemini.transcriptionModel"
    public static let useGeminiTranscriptionKey = "tx.transcription.useGemini"
    /// Flag separada pra Gemini em meetings. Por padrão OFF — Whisper produz
    /// timestamps por frase nativos e intercala mic/app cronologicamente, o
    /// que Gemini com `responseSchema` não respeita (devolve blocão por canal).
    public static let useGeminiMeetingsKey = "tx.transcription.useGeminiForMeetings"

    public static func endpoint(for model: GeminiModel) -> String {
        "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent"
    }
}
