import Foundation

public enum WhisperModel: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case medium = "openai_whisper-medium"
    case largeV3 = "openai_whisper-large-v3"
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo"
    case distilLargeV3 = "distil-whisper_distil-large-v3"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tiny: "Tiny (40 MB)"
        case .base: "Base (75 MB)"
        case .small: "Small (240 MB)"
        case .medium: "Medium (770 MB)"
        case .largeV3: "Large v3 (1.5 GB)"
        case .largeV3Turbo: "Large v3 Turbo (800 MB)"
        case .distilLargeV3: "Distil Large v3 (750 MB) — inglês apenas"
        }
    }

    public var approximateSizeBytes: Int64 {
        switch self {
        case .tiny: 40 * 1_048_576
        case .base: 75 * 1_048_576
        case .small: 240 * 1_048_576
        case .medium: 770 * 1_048_576
        case .largeV3: 1_500 * 1_048_576
        case .largeV3Turbo: 800 * 1_048_576
        case .distilLargeV3: 750 * 1_048_576
        }
    }

    /// Indica se o modelo suporta transcrição em idiomas diferentes de inglês.
    /// `distilLargeV3` foi fine-tunado exclusivamente para inglês — usar em
    /// português produz transcrições em inglês ou degradadas.
    public var supportsMultilingual: Bool {
        switch self {
        case .distilLargeV3: false
        default: true
        }
    }

    /// Large v3: modelo original completo do OpenAI, 1.5 GB, multilíngue.
    /// Qualidade máxima para pt-BR + jargão técnico misto. Latência ~0.8-1.2s
    /// para ditado de 10s no M3 Max. Turbo é mais rápido mas tem qualidade
    /// levemente menor em termos técnicos raros.
    public static let `default`: WhisperModel = .largeV3
}
