import Foundation

/// Locates the `claude` CLI on the user's machine. Tries common install
/// locations first, then falls back to `which claude` on $PATH.
///
/// The returned path may not exist — callers should still verify with
/// `FileManager.isExecutableFile(atPath:)`. Returns the most likely path so
/// the existence check produces a sensible "not installed" status.
enum ClaudeBinary {
    static func locate() -> String {
        BinaryResolver.locate(
            tool: "claude",
            commonPaths: [
                "\(NSHomeDirectory())/.local/bin/claude",  // npm global / curl installer default
                "/opt/homebrew/bin/claude",                // Apple Silicon Homebrew
                "/usr/local/bin/claude",                   // Intel Homebrew / manual install
                "\(NSHomeDirectory())/.claude/local/claude", // legacy Anthropic installer
            ]
        )
    }
}

enum CuaDriverBinary {
    static func locate() -> String {
        BinaryResolver.locate(
            tool: "cua-driver",
            commonPaths: [
                "/usr/local/bin/cua-driver",   // upstream install script default
                "/opt/homebrew/bin/cua-driver",
                "\(NSHomeDirectory())/.local/bin/cua-driver",
            ]
        )
    }
}

/// Resolves a CLI tool's path. Tries (in order):
///   1. Each commonPaths entry — fast file-system check.
///   2. `/usr/bin/env which TOOL` — uses the inherited PATH.
///   3. `/bin/zsh -ilc 'command -v TOOL'` — interactive login shell, sources
///      .zprofile and .zshrc so tools managed by nvm/asdf/fnm/Homebrew shell
///      hooks resolve. Slower, so cached.
/// Returns commonPaths[0] when nothing is found, so callers' existence
/// checks surface a clean "missing" state rather than crashing on "".
enum BinaryResolver {
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static func locate(tool: String, commonPaths: [String]) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[tool] { return cached }
        let resolved = resolveFresh(tool: tool, commonPaths: commonPaths)
        cache[tool] = resolved
        NSLog("🔧 BinaryResolver: \(tool) -> \(resolved)")
        return resolved
    }

    /// Drops the cache so the next locate() re-probes. Use after an install
    /// step so newly-installed binaries become visible without an app restart.
    static func invalidateCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private static func resolveFresh(tool: String, commonPaths: [String]) -> String {
        for path in commonPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let onPath = which(tool) { return onPath }
        if let onShellPath = shellWhich(tool) { return onShellPath }
        return commonPaths[0]
    }

    private static func which(_ tool: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// Interactive login shell lookup. Loads .zprofile + .zshrc so nvm /
    /// asdf-managed tools resolve. Multi-line output is filtered to the last
    /// non-empty line (interactive shells sometimes emit prompts/banners).
    private static func shellWhich(_ tool: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "command -v \(tool)"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let raw = String(data: data, encoding: .utf8) ?? ""
        // Take the LAST non-empty line — banners/prompts emit before our output.
        let candidate = raw.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !candidate.isEmpty, FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
        return candidate
    }
}
