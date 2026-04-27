import Foundation

/// Parses one JSONL line emitted by `codex exec --json`.
///
/// Stream schema reference (verified live against codex-cli 0.124.0):
///   {"type":"thread.started","thread_id":"<uuid>"}
///   {"type":"turn.started"}
///   {"type":"item.started","item":{"id":"item_0","type":"command_execution","command":"...","status":"in_progress"}}
///   {"type":"item.completed","item":{"id":"item_0","type":"command_execution","exit_code":0,"status":"completed","aggregated_output":"..."}}
///   {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"..."}}
///   {"type":"item.completed","item":{"id":"item_2","type":"mcp_tool_call","server":"...","tool":"...","arguments":{...},"status":"completed"}}
///   {"type":"turn.completed","usage":{...}}
///   {"type":"turn.failed","error":{"message":"..."}}
///   {"type":"error","message":"..."}
///
/// The codex stream has no single "final result" event — the LAST `agent_message`
/// item before turn.completed is what the user sees as the agent's reply. We
/// track it as we go and surface it on turn.completed.
enum CodexStreamEventParser {
    static func parse(line: String) -> ParseOutput {
        var out = ParseOutput()
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any]
        else { return out }

        let type = obj["type"] as? String ?? ""
        switch type {
        case "thread.started":
            if let tid = obj["thread_id"] as? String, !tid.isEmpty {
                out.sessionId = tid
            }

        case "turn.started":
            break

        case "item.started":
            guard let item = obj["item"] as? [String: Any] else { break }
            if let event = startEvent(for: item) {
                out.events.append(event)
            }

        case "item.completed":
            guard let item = obj["item"] as? [String: Any] else { break }
            let itemType = item["type"] as? String ?? ""
            switch itemType {
            case "agent_message":
                let text = ParseHelpers.sanitize(
                    (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                )
                if !text.isEmpty {
                    out.events.append(.init(kind: .message, text: text, detail: nil))
                    // Latest agent_message becomes the final result; codex doesn't
                    // emit a dedicated `result` event the way Claude does.
                    out.finalResult = text
                }

            case "reasoning":
                // Codex's chain-of-thought is verbose. Skip — keeps the activity
                // feed focused on actions and visible output, like Claude.
                break

            case "command_execution":
                let exit = item["exit_code"] as? Int ?? 0
                let isError = exit != 0
                let cmd = ParseHelpers.sanitize(item["command"] as? String ?? "(command)")
                let output = ParseHelpers.sanitize(
                    (item["aggregated_output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let cleanedOutput = ParseHelpers.stripLeadingWarningGlyphs(output)
                let detail: String?
                if cleanedOutput.isEmpty {
                    detail = "exit \(exit)"
                } else {
                    detail = ParseHelpers.condense(cleanedOutput)
                }
                let label = isError ? "Command failed (\(exit))" : ParseHelpers.condense(cmd)
                out.events.append(.init(
                    kind: isError ? .error : .toolResult,
                    text: label,
                    detail: detail
                ))

            case "mcp_tool_call":
                let server = item["server"] as? String ?? ""
                let tool = item["tool"] as? String ?? "tool"
                let status = item["status"] as? String ?? "completed"
                let isError = status == "failed"
                let args = item["arguments"] as? [String: Any] ?? [:]
                let combined = server.isEmpty ? tool : "mcp__\(server)__\(tool)"
                let (label, hint) = ParseHelpers.humanize(toolName: combined, input: args)
                let resultText = ParseHelpers.sanitize(
                    (item["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let detail: String? = {
                    if !resultText.isEmpty {
                        return ParseHelpers.condense(ParseHelpers.stripLeadingWarningGlyphs(resultText))
                    }
                    return hint.map(ParseHelpers.sanitize)
                }()
                out.events.append(.init(
                    kind: isError ? .error : .toolResult,
                    text: ParseHelpers.sanitize(label),
                    detail: detail
                ))

            default:
                break
            }

        case "turn.completed":
            // No-op — finalResult was set as agent_messages came through.
            break

        case "turn.failed":
            out.didError = true
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                let cleaned = ParseHelpers.sanitize(msg)
                out.events.append(.init(kind: .error, text: "Turn failed", detail: ParseHelpers.condense(cleaned)))
                out.finalResult = cleaned
            } else {
                out.events.append(.init(kind: .error, text: "Turn failed", detail: nil))
            }

        case "error":
            out.didError = true
            if let msg = obj["message"] as? String {
                let cleaned = ParseHelpers.sanitize(msg)
                out.events.append(.init(kind: .error, text: "Error", detail: ParseHelpers.condense(cleaned)))
                out.finalResult = cleaned
            }

        default:
            break
        }

        return out
    }

    /// Activity row for the *start* of a long-running item (command execution,
    /// MCP tool call). Mirrors Claude's tool_use → toolCall pairing so the user
    /// sees "X is happening" before the result lands.
    private static func startEvent(for item: [String: Any]) -> ActivityEvent? {
        let itemType = item["type"] as? String ?? ""
        switch itemType {
        case "command_execution":
            let cmd = ParseHelpers.sanitize(item["command"] as? String ?? "(command)")
            return .init(kind: .toolCall, text: "Running command", detail: ParseHelpers.condense(cmd))

        case "mcp_tool_call":
            let server = item["server"] as? String ?? ""
            let tool = item["tool"] as? String ?? "tool"
            let args = item["arguments"] as? [String: Any] ?? [:]
            let combined = server.isEmpty ? tool : "mcp__\(server)__\(tool)"
            let (label, hint) = ParseHelpers.humanize(toolName: combined, input: args)
            return .init(
                kind: .toolCall,
                text: ParseHelpers.sanitize(label),
                detail: hint.map(ParseHelpers.sanitize)
            )

        default:
            return nil
        }
    }
}
