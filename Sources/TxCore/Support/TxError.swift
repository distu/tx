import Foundation

public enum TxError: LocalizedError, Sendable {
    case permissionDenied(String)
    case processNotFound(pid_t)
    case processSilent(pid_t)
    case coreAudioFailure(OSStatus, String)
    case audioEngineFailure(String)
    case databaseFailure(String)
    case transcriptionFailure(String)
    case modelNotReady
    case invalidState(String)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let what):
            "Permissão negada: \(what)"
        case .processNotFound(let pid):
            "Processo não encontrado (PID \(pid))"
        case .processSilent(let pid):
            "Processo não tem áudio ativo (PID \(pid))"
        case .coreAudioFailure(let status, let op):
            "Core Audio falhou em \(op): status \(status)"
        case .audioEngineFailure(let msg):
            "AVAudioEngine falhou: \(msg)"
        case .databaseFailure(let msg):
            "Erro no banco: \(msg)"
        case .transcriptionFailure(let msg):
            "Erro na transcrição: \(msg)"
        case .modelNotReady:
            "Modelo Whisper ainda não está pronto"
        case .invalidState(let msg):
            "Estado inválido: \(msg)"
        case .fileSystem(let msg):
            "Erro de sistema de arquivos: \(msg)"
        }
    }
}
