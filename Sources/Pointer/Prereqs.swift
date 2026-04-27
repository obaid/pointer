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
        /// Per-engine install status. Keyed by engine — Pointer needs at
        /// least one resolved entry to run.
        var engines: [RunnerEngine: CheckStatus] = [:]
        /// cua-driver binary present + registered with every installed engine.
        var computer: CheckStatus = .unknown
        /// Mic + speech recognition authorized.
        var voice: CheckStatus = .unknown

        /// Engines that are confirmed installed.
        var installedEngines: [RunnerEngine] {
            RunnerEngine.allCases.filter { (engines[$0] ?? .missing).isResolved }
        }

        /// Voice is optional. Computer access matters only if at least one
        /// engine is present (no point checking otherwise). Continue is
        /// enabled when there's at least one engine + computer access.
        var allReady: Bool {
            !installedEngines.isEmpty && computer.isResolved
        }
    }

    @Published private(set) var state = State()

    private let cuaDriverPath: String = CuaDriverBinary.locate()
    private let cuaInstallScript = "https://raw.githubusercontent.com/trycua/cua/main/libs/cua-driver/scripts/install.sh"

    // MARK: - Detect

    func runAllChecks() async {
        for engine in RunnerEngine.allCases {
            state.engines[engine] = .checking
        }
        state.computer = .checking
        state.voice = .checking

        async let engineResults = checkAllEngines()
        async let computer: CheckStatus = checkComputerAccess()
        async let voice: CheckStatus = checkVoice()

        let (results, c, v) = await (engineResults, computer, voice)
        for (engine, status) in results {
            state.engines[engine] = status
        }
        state.computer = c
        state.voice = v
    }

    private func checkAllEngines() async -> [(RunnerEngine, CheckStatus)] {
        await withTaskGroup(of: (RunnerEngine, CheckStatus).self) { group in
            for engine in RunnerEngine.allCases {
                group.addTask { [weak self] in
                    let status = await (self?.checkEngine(engine) ?? .unknown)
                    return (engine, status)
                }
            }
            var collected: [(RunnerEngine, CheckStatus)] = []
            for await result in group { collected.append(result) }
            return collected
        }
    }

    private func checkEngine(_ engine: RunnerEngine) async -> CheckStatus {
        let path = engine.locateBinary()
        guard FileManager.default.isExecutableFile(atPath: path) else { return .missing }
        let result = await Shell.run(path, ["--version"])
        if result.exitCode == 0 { return .ok }
        return .failed(result.stderr.isEmpty ? "Could not run \(engine.displayName)" : result.stderr)
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

    /// Computer access is OK when the cua-driver binary exists AND is
    /// registered as an MCP server with EVERY installed engine. If no engine
    /// is installed yet, we can't check — return missing so the row stays
    /// actionable once one is installed.
    private func checkComputerAccess() async -> CheckStatus {
        guard FileManager.default.isExecutableFile(atPath: cuaDriverPath) else { return .missing }

        let installed = RunnerEngine.allCases.filter {
            FileManager.default.isExecutableFile(atPath: $0.locateBinary())
        }
        guard !installed.isEmpty else { return .missing }

        for engine in installed {
            let registered = await isCuaRegistered(with: engine)
            if !registered { return .missing }
        }
        return .ok
    }

    private func isCuaRegistered(with engine: RunnerEngine) async -> Bool {
        let result = await Shell.run(engine.locateBinary(), ["mcp", "list"])
        guard result.exitCode == 0 else { return false }
        return result.stdout.contains("cua-driver")
    }

    // MARK: - Fix actions

    /// Triggers the system mic + speech-recognition prompts. If the user has already
    /// denied either, opens System Settings instead so they can flip the toggle.
    func requestVoice() async {
        state.voice = .checking

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

    /// Installs the cua-driver binary if missing and registers it with every
    /// engine the user has installed. Re-running is safe — idempotent on the
    /// "already exists" stderr response from each engine's `mcp add`.
    func installComputerAccess() async -> Bool {
        if !FileManager.default.isExecutableFile(atPath: cuaDriverPath) {
            state.computer = .checking
            let install = await Shell.runShell("/bin/bash -c \"$(curl -fsSL \(cuaInstallScript))\"")
            if install.exitCode != 0 {
                state.computer = .failed(install.stderr.isEmpty ? "Install failed" : install.stderr)
                return false
            }
        }

        let installed = RunnerEngine.allCases.filter {
            FileManager.default.isExecutableFile(atPath: $0.locateBinary())
        }
        guard !installed.isEmpty else {
            state.computer = .failed("Install at least one AI engine first.")
            return false
        }

        for engine in installed {
            if await isCuaRegistered(with: engine) { continue }
            let register = await Shell.run(
                engine.locateBinary(),
                ["mcp", "add", "cua-driver", "--", cuaDriverPath, "mcp"]
            )
            if register.exitCode != 0 && !register.stderr.contains("already exists") {
                state.computer = .failed("Could not register with \(engine.displayName): \(register.stderr)")
                return false
            }
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

    static func runShell(_ commandLine: String) async -> Result {
        await run("/bin/zsh", ["-lc", commandLine])
    }

    static func runAppleScriptDetached(_ source: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        try? process.run()
    }
}
