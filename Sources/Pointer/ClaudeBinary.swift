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

/// Resolves a CLI tool's path: probes a list of common locations, then falls
/// back to `which`. Returns the first existing executable, or — if nothing is
/// found — the first candidate so existence checks elsewhere surface a clean
/// "missing" state rather than crashing on an empty path.
enum BinaryResolver {
    static func locate(tool: String, commonPaths: [String]) -> String {
        for path in commonPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let onPath = which(tool) { return onPath }
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
        return path.isEmpty ? nil : path
    }
}
