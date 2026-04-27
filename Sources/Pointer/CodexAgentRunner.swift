import Foundation

/// Spawns Codex CLI (`codex exec --json`) and streams JSONL events into the
/// AgentStore. Same shape as ClaudeAgentRunner but with codex-specific args
/// and parser. Owns the Process so AgentStore.cancel(taskId:) can terminate it.
///
/// Args we always pass:
///   --json                                       streaming JSONL output
///   --skip-git-repo-check                        we run in ~/pointer-workspace
///   --dangerously-bypass-approvals-and-sandbox   match Claude's --dangerously-skip-permissions UX
enum CodexAgentRunner {
    static func run(prompt: String, resumeSessionId: String?, taskId: UUID, store: AgentStore?) async {
        guard let store else { return }
        let codexPath = CodexBinary.locate()
        let workspace = AgentWorkspace.ensure()
        NSLog("🤖 CodexAgentRunner.run prompt=\(prompt.prefix(80)) resume=\(resumeSessionId ?? "<new>")")

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: codexPath)
        var args: [String] = ["exec"]
        if let resumeSessionId {
            args += ["resume", resumeSessionId]
        }
        args += [
            "--json",
            "--skip-git-repo-check",
            "--dangerously-bypass-approvals-and-sandbox",
        ]
        args.append(prompt)
        process.arguments = args
        process.currentDirectoryURL = workspace
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment

        let started = Date()
        do {
            try process.run()
        } catch {
            await store.appendActivity(
                .init(kind: .error, text: "Failed to launch agent", detail: error.localizedDescription),
                for: taskId
            )
            await store.finish(taskId: taskId, state: .failed(message: error.localizedDescription))
            return
        }
        await store.registerProcess(process, for: taskId)

        let stderrTask = Task.detached(priority: .utility) {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        var finalResult: String?
        var sawError = false
        let stdoutHandle = stdoutPipe.fileHandleForReading

        do {
            for try await line in stdoutHandle.bytes.lines {
                if Task.isCancelled { break }
                let parsed = CodexStreamEventParser.parse(line: line)
                if let sid = parsed.sessionId {
                    await store.setSessionId(sid, for: taskId)
                }
                for event in parsed.events {
                    await store.appendActivity(event, for: taskId)
                }
                if parsed.didError { sawError = true }
                if let result = parsed.finalResult { finalResult = result }
            }
        } catch {
            NSLog("🤖 codex stream read error: \(error.localizedDescription)")
        }

        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(started)
        let stderrData = await stderrTask.value
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        NSLog("🤖 codex exited code=\(process.terminationStatus) in \(String(format: "%.1f", elapsed))s")

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
