import Foundation

/// Spawns Claude Code (`claude -p --output-format stream-json --verbose`) and
/// streams NDJSON events into the AgentStore as they arrive. Owns the Process
/// reference so AgentStore.cancel(taskId:) can terminate the run.
enum ClaudeAgentRunner {
    static func run(
        prompt: String,
        resumeSessionId: String?,
        modelArg: String? = nil,
        taskId: UUID,
        store: AgentStore?
    ) async {
        let claudePath = ClaudeBinary.locate()
        guard let store else { return }

        let workspace = AgentWorkspace.ensure()
        NSLog("🤖 ClaudeAgentRunner.run prompt=\(prompt.prefix(80)) resume=\(resumeSessionId ?? "<new>")")

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: claudePath)
        var args = [
            "--dangerously-skip-permissions",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
        ]
        if let modelArg {
            args += ["--model", modelArg]
        }
        if let resumeSessionId {
            args += ["-r", resumeSessionId]
        }
        args += ["-p", prompt]
        process.arguments = args
        process.currentDirectoryURL = workspace
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment

        let started = Date()
        do {
            try process.run()
        } catch {
            await store.appendActivity(.init(kind: .error, text: "Failed to launch agent", detail: error.localizedDescription), for: taskId)
            await store.finish(taskId: taskId, state: .failed(message: error.localizedDescription))
            return
        }
        await store.registerProcess(process, for: taskId)

        // Drain stderr concurrently so it doesn't block; we only surface it on non-zero exit.
        let stderrTask = Task.detached(priority: .utility) {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        var finalResult: String?
        var sawError = false
        let stdoutHandle = stdoutPipe.fileHandleForReading

        do {
            for try await line in stdoutHandle.bytes.lines {
                if Task.isCancelled { break }
                let parsed = ClaudeStreamEventParser.parse(line: line)
                if let sid = parsed.sessionId {
                    await store.setSessionId(sid, for: taskId)
                }
                if !parsed.events.isEmpty {
                    for event in parsed.events {
                        await store.appendActivity(event, for: taskId)
                    }
                }
                if let result = parsed.finalResult {
                    finalResult = result
                    sawError = parsed.didError
                }
            }
        } catch {
            NSLog("🤖 stream read error: \(error.localizedDescription)")
        }

        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(started)
        let stderrData = await stderrTask.value
        let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        NSLog("🤖 claude exited code=\(process.terminationStatus) in \(String(format: "%.1f", elapsed))s")

        let finalState: TaskState
        if process.terminationStatus == 0 && !sawError {
            let summary = finalResult?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Done."
            finalState = .done(summary: summary.isEmpty ? "Done." : summary)
        } else if process.terminationStatus == SIGTERM || process.terminationStatus == 143 {
            finalState = .cancelled
        } else {
            let detail: String
            if let r = finalResult, !r.isEmpty {
                detail = r
            } else if !stderrText.isEmpty {
                detail = stderrText
            } else {
                detail = "Agent exited with code \(process.terminationStatus)"
            }
            finalState = .failed(message: detail)
        }
        await store.finish(taskId: taskId, state: finalState)
    }
}

/// The directory both engines run in. ~/pointer-workspace — outside of any
/// project so per-engine settings (codex's trust_level, claude's CWD-scoped
/// permissions) don't pollute the user's real repos.
enum AgentWorkspace {
    static func ensure() -> URL {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("pointer-workspace")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
