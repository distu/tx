import Foundation
import TxCore

/// Usa exclusivamente o login oficial do Codex CLI para tarefas de texto.
/// O CLI não recebe áudio; transcrição continua no provedor escolhido para ASR.
actor CodexCLIIntelligence {
    static let shared = CodexCLIIntelligence()

    enum CLIError: LocalizedError {
        case notInstalled
        case notLoggedIn
        case commandFailed(String)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Codex CLI não encontrado neste Mac."
            case .notLoggedIn: "Faça login no Codex em Configurações > Inteligência."
            case .commandFailed(let action): "Codex não concluiu \(action). Confira o login e os limites da assinatura."
            case .emptyOutput: "Codex terminou sem gerar texto."
            }
        }
    }

    private func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CLIError.notInstalled
        }
        return path
    }

    private func subscriptionEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // A escolha "assinatura" não pode cair silenciosamente em cobrança por API key.
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_ACCESS_TOKEN")
        environment.removeValue(forKey: "OPENAI_BASE_URL")
        environment.removeValue(forKey: "OPENAI_API_BASE")
        return environment
    }

    func isLoggedIn() async -> Bool {
        guard let path = try? executable() else { return false }
        let process = Process()
        process.executableURL = path
        process.arguments = ["login", "status"]
        process.environment = subscriptionEnvironment()
        let output = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        guard (try? process.run()) != nil else { return false }
        await wait(for: process, seconds: 15)
        let status = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return process.terminationStatus == 0 && status.contains("Logged in using ChatGPT")
    }

    /// O login interativo oficial abre o navegador; nunca lemos os tokens do CLI.
    func login() async throws {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = ["login"]
        process.environment = subscriptionEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        await wait(for: process, seconds: 180)
        guard process.terminationStatus == 0, await isLoggedIn() else {
            throw CLIError.commandFailed("o login")
        }
    }

    func generate(prompt: String, sessionId: UUID, mode: IntelligenceMode) async throws -> IntelligenceArtifact {
        guard await isLoggedIn() else { throw CLIError.notLoggedIn }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tx-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("response.txt")

        let process = Process()
        process.executableURL = try executable()
        process.currentDirectoryURL = directory
        process.environment = subscriptionEnvironment()
        process.arguments = [
            "exec", "-", "--model", "gpt-6.1-sol", "--sandbox", "read-only",
            "--skip-git-repo-check", "--ephemeral", "--ignore-user-config",
            "--output-last-message", output.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input
        try process.run()
        let instructions = "Responda apenas ao pedido abaixo. Não execute comandos nem leia outros arquivos.\n\n" + prompt
        try input.fileHandleForWriting.write(contentsOf: Data(instructions.utf8))
        try? input.fileHandleForWriting.close()
        await wait(for: process, seconds: 180)
        guard process.terminationStatus == 0 else { throw CLIError.commandFailed("a geração") }
        let content = try String(contentsOf: output, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw CLIError.emptyOutput }
        return IntelligenceArtifact(sessionId: sessionId, mode: mode, content: content)
    }

    private func wait(for process: Process, seconds: Int) async {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}
