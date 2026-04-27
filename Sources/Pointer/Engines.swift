import Foundation

/// Which underlying agent CLI handles a given task. Pointer is engine-agnostic
/// in its UX — engine-specific differences (command construction, NDJSON
/// schema, resume semantics) are isolated to per-engine runners and parsers.
enum RunnerEngine: String, Codable, CaseIterable, Identifiable, Hashable {
    case claude
    case codex

    var id: Self { self }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Short-form badge text (used in tight orb / history pills).
    var badgeText: String { displayName }

    /// SF Symbol for the engine, used in chips and onboarding.
    var symbolName: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "command"
        }
    }

    /// Marketing URL pointed to from onboarding when an engine is missing.
    var installURL: URL? {
        switch self {
        case .claude: return URL(string: "https://docs.claude.com/en/docs/claude-code")
        case .codex: return URL(string: "https://developers.openai.com/codex")
        }
    }

    /// One-line install hint shown when the user has neither engine.
    var installHint: String {
        switch self {
        case .claude: return "Install with: npm install -g @anthropic-ai/claude-code"
        case .codex: return "Install with: npm install -g @openai/codex"
        }
    }

    func locateBinary() -> String {
        switch self {
        case .claude: return ClaudeBinary.locate()
        case .codex: return CodexBinary.locate()
        }
    }
}

/// Locates the `codex` CLI. Common install locations + $PATH fallback. Mirrors
/// ClaudeBinary.locate() so the resolution rules are predictable.
enum CodexBinary {
    static func locate() -> String {
        BinaryResolver.locate(
            tool: "codex",
            commonPaths: [
                "/opt/homebrew/bin/codex",                       // Apple Silicon Homebrew cask
                "/usr/local/bin/codex",                          // Intel Homebrew / manual
                "\(NSHomeDirectory())/.local/bin/codex",         // user-local
                // npm global paths vary by node version manager — $PATH fallback covers them.
            ]
        )
    }
}

/// User's preferred engine — used as the default when launching a new task.
/// Persists in UserDefaults so it survives restarts. Reads default to .claude
/// if the key has never been written.
enum EnginePreference {
    private static let key = "pointer.preferredEngine"

    static var current: RunnerEngine {
        get {
            if let raw = UserDefaults.standard.string(forKey: key),
               let engine = RunnerEngine(rawValue: raw) {
                return engine
            }
            return .claude
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
