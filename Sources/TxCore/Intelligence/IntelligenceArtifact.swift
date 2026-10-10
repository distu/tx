import Foundation

/// Tipo de artefato de inteligência que pode ser gerado a partir de uma transcrição.
public enum IntelligenceMode: String, CaseIterable, Identifiable, Sendable {
    case ata      = "ata"
    case briefing = "briefing"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ata:      "Ata"
        case .briefing: "Briefing"
        }
    }

    public var description: String {
        switch self {
        case .ata:
            "Documento completo estruturado por tópicos, sem perder nenhuma informação da reunião."
        case .briefing:
            "Resumo executivo com destaques, decisões tomadas e lista de ações."
        }
    }

    public var systemImage: String {
        switch self {
        case .ata:      "doc.text.fill"
        case .briefing: "list.bullet.clipboard.fill"
        }
    }
}

/// Artefato gerado pelo IntelligenceEngine.
public struct IntelligenceArtifact: Identifiable, Sendable {
    public let id: UUID
    public let sessionId: UUID
    public let mode: IntelligenceMode
    public let content: String
    public let generatedAt: Date

    public init(sessionId: UUID, mode: IntelligenceMode, content: String) {
        self.id          = UUID()
        self.sessionId   = sessionId
        self.mode        = mode
        self.content     = content
        self.generatedAt = .now
    }
}
