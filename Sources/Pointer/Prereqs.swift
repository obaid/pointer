import Foundation
import AppKit
import AVFoundation
import Speech

/// Detects what Pointer needs to function and (where safe) fixes it automatically.
/// User-facing language never mentions internals like "cua-driver" or "MCP".
@MainActor
final class PrereqsChecker: ObservableObject {

    enum CheckStatus: Equatable {
        case unknown
        case checking
        case ok
        case missing
        case failed(String)

        var isResolved: Bool {
            if case .ok = self { return true } else { return false }
        }
    }

    struct State: Equatable {
        var aiEngine: CheckStatus = .unknown   // Claude Code installed
        var computer: CheckStatus = .unknown   // cua-driver binary + registered
        var voice: CheckStatus = .unknown      // mic + speech recognition authorized

        /// Voice is optional — Pointer works fully without it. Don't gate Continue on voice.
        var allReady: Bool { aiEngine.isResolved && computer.isResolved }
    }

    @Published private(set) var state = State()

    /// Resolved at startup — both binaries are looked up in standard install
    /// locations and then on $PATH so the app works regardless of where the
    /// user installed them.
    private let claudePath: String = ClaudeBinary.locate()
    private let cuaDriverPath: String = CuaDriverBinary.locate()
    private let cuaInstallScript = "https://raw.githubusercontent.com/trycua/cua/main/libs/cua-driver/scripts/install.sh"

    // MARK: - Detect

    func runAllChecks() async {
        state.aiEngine = .checking
        state.computer = .checking
        state.voice = .checking

        async let engine: CheckStatus = checkAIEngine()
        async let computer: CheckStatus = checkComputerAccess()
        async let voice: CheckStatus = checkVoice()

        let (e, c, v) = await (engine, computer, voice)
        state.aiEngine = e
        state.computer = c
        state.voice = v
    }

    private func checkAIEngine() async -> CheckStatus {
        guard FileManager.default.isExecutableFile(atPath: claudePath) else { return .missing }
        let result = await Shell.run(claudePath, ["--version"])
        return result.exitCode == 0 ? .ok : .failed(result.stderr.isEmpty ? "Could not run AI engine" : result.stderr)
    }

    /// Mic + speech-recognition authorization. Both must be authorized for `.ok`.
    /// Reads cached status only — never prompts. Use `requestVoice()` to prompt.
    private func checkVoice() async -> CheckStatus {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        switch (mic, speech) {
        case (.authorized, .authorized):
            return .ok
        case (.denied, _), (.restricted, _):
            return .failed("Microphone access denied — open System Settings to enable.")
        case (_, .denied), (_, .restricted):
            return .failed("Speech recognition denied — open System Settings to enable.")
        default:
            return .missing
        }
    }

    private func checkComputerAccess() async -> CheckStatus {
        guard FileManager.default.isExecutableFile(atPath: cuaDriverPath) else { return .missing }
        let listed = await Shell.run(claudePath, ["mcp", "list"])
        if listed.exitCode != 0 {
            return .failed("Could not query AI engine plugins")
        }
        return listed.stdout.contains("cua-driver") ? .ok : .missing
    }

    // MARK: - Fix actions

    /// Triggers the system mic + speech-recognition prompts. If the user has already
    /// denied either, opens System Settings instead so they can flip the toggle.
    func requestVoice() async {
        state.voice = .checking

        // If already denied, can't re-prompt — point user at Settings.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            openMicrophoneSettings()
            state.voice = await checkVoice()
            return
        }
        if SFSpeechRecognizer.authorizationStatus() == .denied {
            openSpeechRecognitionSettings()
            state.voice = await checkVoice()
            return
        }

        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        let speechGranted: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }

        if micGranted && speechGranted {
            state.voice = .ok
        } else if !micGranted {
            state.voice = .failed("Microphone access denied — open System Settings to enable.")
        } else {
            state.voice = .failed("Speech recognition denied — open System Settings to enable.")
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSpeechRecognitionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Installs the cua-driver binary if missing and registers it as an MCP plugin.
    /// Returns true on success.
    func installComputerAccess() async -> Bool {
        if !FileManager.default.isExecutableFile(atPath: cuaDriverPath) {
            state.computer = .checking
            let install = await Shell.runShell("/bin/bash -c \"$(curl -fsSL \(cuaInstallScript))\"")
            if install.exitCode != 0 {
                state.computer = .failed(install.stderr.isEmpty ? "Install failed" : install.stderr)
                return false
            }
        }
        // Register with claude.
        let register = await Shell.run(claudePath, ["mcp", "add", "cua-driver", "--", cuaDriverPath, "mcp"])
        if register.exitCode != 0 && !register.stderr.contains("already exists") {
            state.computer = .failed(register.stderr.isEmpty ? "Registration failed" : register.stderr)
            return false
        }
        state.computer = .ok
        return true
    }
}

/// Minimal shell-out helpers.
enum Shell {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Run a command at an absolute path with explicit args. No shell, no escaping concerns.
    static func run(_ executable: String, _ args: [String]) async -> Result {
        await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.environment = ProcessInfo.processInfo.environment
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: Result(exitCode: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(
                    returning: Result(
                        exitCode: process.terminationStatus,
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? ""
                    )
                )
            }
        }
    }

    /// Run a full shell command line via /bin/zsh -lc. Use sparingly — prefer the args form.
    static func runShell(_ commandLine: String) async -> Result {
        await run("/bin/zsh", ["-lc", commandLine])
    }

    /// Fire-and-forget AppleScript (used to open Terminal for the user to log in).
    static func runAppleScriptDetached(_ source: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        try? process.run()
    }
}
