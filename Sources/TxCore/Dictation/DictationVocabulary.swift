import Foundation

/// Vocabulário customizado do ditado. Dois mecanismos:
///
/// 1. **Initial prompt** (`terms`): texto livre injetado antes do decoder
///    do Whisper via `promptTokens`. Enviesa o modelo a reconhecer termos
///    específicos (tech, nomes próprios, jargões). Não é "treino" — é
///    condicionamento contextual que funciona instantaneamente.
///
/// 2. **Substituições** (`substitutions`): lista `from -> to` aplicada após
///    a transcrição. Útil para corrigir padrões recorrentes (ex: transcrição
///    fonética "tipe script" -> "TypeScript").
public struct DictationVocabulary: Codable, Sendable {
    public var terms: String
    public var substitutions: [Substitution]

    public struct Substitution: Codable, Sendable, Identifiable, Hashable {
        public var id: UUID
        public var from: String
        public var to: String
        public var caseSensitive: Bool

        public init(id: UUID = UUID(), from: String, to: String, caseSensitive: Bool = false) {
            self.id = id
            self.from = from
            self.to = to
            self.caseSensitive = caseSensitive
        }
    }

    public init(terms: String, substitutions: [Substitution]) {
        self.terms = terms
        self.substitutions = substitutions
    }

    /// Defaults otimizados para contexto de desenvolvimento de software.
    public static let `default` = DictationVocabulary(
        terms: """
        Git, GitHub, GitLab, pull request, merge request, commit, branch, rebase, cherry-pick, stash.
        TypeScript, JavaScript, Node.js, React, Next.js, Vite, Tailwind CSS, shadcn, Zustand, TanStack Query.
        Swift, SwiftUI, AppKit, Xcode, WhisperKit, GRDB, Sparkle.
        Python, FastAPI, SQLAlchemy, Alembic, Pydantic, Django.
        Docker, Kubernetes, Terraform, Helm, Nginx, Postgres, Redis, SQLite, FTS5.
        AWS, GCP, Azure, S3, Lambda, DynamoDB, Supabase, Cloudflare, Vercel.
        Claude Code, Cursor, Warp, VSCode, iTerm, tmux, neovim.
        pnpm, yarn, npm, bun, brew, asdf, pyenv.
        Apple Silicon, M1, M2, M3 Max, CoreML, Metal, Neural Engine.
        OpenAI, Anthropic, Sonnet, Opus, Haiku, GPT, Gemini, Llama.
        tx, meeting notes, voice dictation, transcription.
        async, await, actor, sendable, generics, trait, closure.
        frontend, backend, fullstack, DevOps, SRE, QA.
        branch feature, bugfix, hotfix, release, main, master, develop, staging, produção.
        deploy, rollback, CI, CD, pipeline, workflow, runner, artifact.
        endpoint, webhook, payload, schema, migration, rollout.
        """,
        substitutions: [
            .init(from: "(?i)\\btipe ?script\\b", to: "TypeScript"),
            .init(from: "(?i)\\bjava ?script\\b", to: "JavaScript"),
            .init(from: "(?i)\\bnode ?js\\b", to: "Node.js"),
            .init(from: "(?i)\\bnext ?js\\b", to: "Next.js"),
            .init(from: "(?i)\\bnuxt ?js\\b", to: "Nuxt.js"),
            .init(from: "(?i)\\breact ?js\\b", to: "React"),
            .init(from: "(?i)\\bpull request\\b", to: "pull request"),
            .init(from: "(?i)\\bmerge request\\b", to: "merge request"),
            .init(from: "(?i)\\bpost(?:é|e|es) ?gres(?:ql)?\\b", to: "Postgres"),
            .init(from: "(?i)\\bapi (?:rest)?\\b", to: "API REST"),
            .init(from: "(?i)\\bkubernet(?:i|e)s\\b", to: "Kubernetes"),
            .init(from: "(?i)\\bdock(?:e|é)r\\b", to: "Docker"),
            .init(from: "(?i)\\bgit ?hub\\b", to: "GitHub"),
            .init(from: "(?i)\\bgit ?lab\\b", to: "GitLab"),
            .init(from: "(?i)\\bfast ?api\\b", to: "FastAPI"),
            .init(from: "(?i)\\bclaude code\\b", to: "Claude Code"),
        ]
    )

    // MARK: - Persistence

    private static let storageIdentifier = "tx.dictation.vocabulary.v1"

    public static func load() -> DictationVocabulary {
        guard let data = UserDefaults.standard.data(forKey: storageIdentifier),
              let vocab = try? JSONDecoder().decode(DictationVocabulary.self, from: data)
        else { return .default }
        return vocab
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageIdentifier)
        }
    }

    // MARK: - Application

    /// Aplica substituições regex em sequência ao texto transcrito.
    public func applySubstitutions(_ text: String) -> String {
        var result = text
        for sub in substitutions {
            let options: NSRegularExpression.Options = sub.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: sub.from, options: options) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: sub.to)
        }
        return result
    }
}
