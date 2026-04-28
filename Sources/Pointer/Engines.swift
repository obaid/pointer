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

    /// Curated list of models the chip surfaces. The first entry (`nil` cliArg)
    /// is "Default" — pass no --model flag and let the engine choose.
    /// Aliases used for Claude so they auto-resolve to the latest minor.
    var availableModels: [RunnerModel] {
        switch self {
        case .claude:
            return [
                .init(displayName: "Default",   cliArg: nil),
                .init(displayName: "Opus 4.7",  cliArg: "opus"),
                .init(displayName: "Sonnet 4.6", cliArg: "sonnet"),
                .init(displayName: "Haiku 4.5", cliArg: "haiku"),
            ]
        case .codex:
            return [
                .init(displayName: "Default",     cliArg: nil),
                .init(displayName: "gpt-5",       cliArg: "gpt-5"),
                .init(displayName: "gpt-5-codex", cliArg: "gpt-5-codex"),
                .init(displayName: "gpt-5.5",     cliArg: "gpt-5.5"),
            ]
        }
    }

    /// Whether reasoning effort is configurable for this engine via the CLI.
    /// Only Codex exposes `model_reasoning_effort` — Claude has no equivalent
    /// flag (extended thinking is API-only, not CLI-configurable).
    var supportsReasoningEffort: Bool {
        switch self {
        case .codex: return true
        case .claude: return false
        }
    }
}

/// One picker entry. `cliArg` of nil means "use the engine's own default" —
/// don't pass --model / -m at all.
struct RunnerModel: Hashable, Identifiable {
    let displayName: String
    let cliArg: String?
    var id: String { cliArg ?? "_default" }
}

/// Codex's `model_reasoning_effort` knob. `nil` = leave it to the engine.
enum ReasoningEffort: String, CaseIterable, Identifiable, Hashable, Codable {
    case low, medium, high
    var id: Self { self }
    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
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

/// User's saved preferences for the next task: engine, per-engine model,
/// and reasoning effort (Codex only). Persists in UserDefaults so choices
/// survive restarts. `nil` for model/effort means "let the engine decide."
enum EnginePreference {
    private static let engineKey = "pointer.preferredEngine"
    private static let modelKeyPrefix = "pointer.preferredModel."
    private static let effortKey = "pointer.preferredReasoningEffort"

    static var current: RunnerEngine {
        get {
            if let raw = UserDefaults.standard.string(forKey: engineKey),
               let engine = RunnerEngine(rawValue: raw) {
                return engine
            }
            return .claude
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: engineKey)
        }
    }

    /// Per-engine model preference. nil = "use engine default" (no --model flag).
    static func preferredModel(for engine: RunnerEngine) -> String? {
        UserDefaults.standard.string(forKey: modelKeyPrefix + engine.rawValue)
    }

    static func setPreferredModel(_ model: String?, for engine: RunnerEngine) {
        let key = modelKeyPrefix + engine.rawValue
        if let model {
            UserDefaults.standard.set(model, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Reasoning effort preference. Currently only used by Codex.
    static var preferredReasoningEffort: ReasoningEffort? {
        get {
            UserDefaults.standard.string(forKey: effortKey).flatMap(ReasoningEffort.init(rawValue:))
        }
        set {
            if let value = newValue {
                UserDefaults.standard.set(value.rawValue, forKey: effortKey)
            } else {
                UserDefaults.standard.removeObject(forKey: effortKey)
            }
        }
    }
}
