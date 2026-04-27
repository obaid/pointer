import Foundation

/// Parses one NDJSON line emitted by `claude -p --output-format stream-json` into an ActivityEvent.
///
/// Stream schema reference (subset we care about):
///   {"type":"system","subtype":"init",...}
///   {"type":"assistant","message":{"content":[{"type":"text","text":"..."}]}}
///   {"type":"assistant","message":{"content":[{"type":"tool_use","id":"...","name":"...","input":{...}}]}}
///   {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"...","content":...}]}}
///   {"type":"result","subtype":"success","result":"...","is_error":false,...}
///
/// Returns nil for lines we don't surface to the user (e.g. blank text deltas, unknown types).
enum StreamEventParser {
    struct ParseOutput {
        var events: [ActivityEvent] = []
        var finalResult: String? = nil
        var didError: Bool = false
        var sessionId: String? = nil
    }

    static func parse(line: String) -> ParseOutput {
        var out = ParseOutput()
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any]
        else { return out }

        // Session id appears on most events; capture it whenever present.
        if let id = obj["session_id"] as? String, !id.isEmpty {
            out.sessionId = id
        }

        let type = obj["type"] as? String ?? ""
        switch type {
        case "system":
            // Initialization / config noise — skip events but keep the session id.
            break

        case "assistant":
            guard
                let message = obj["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { break }
            for block in content {
                let blockType = block["type"] as? String ?? ""
                switch blockType {
                case "tool_use":
                    let raw = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    let (label, detail) = humanize(toolName: raw, input: input)
                    out.events.append(.init(kind: .toolCall, text: sanitize(label), detail: detail.map(sanitize)))
                case "text":
                    let trimmed = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        // Show the prose itself; ActivityRow will lineLimit if long.
                        // The full text is also surfaced in the RESULT block on completion.
                        out.events.append(.init(kind: .message, text: sanitize(trimmed), detail: nil))
                    }
                default:
                    break
                }
            }

        case "user":
            guard
                let message = obj["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { break }
            for block in content {
                let blockType = block["type"] as? String ?? ""
                if blockType == "tool_result" {
                    let isError = (block["is_error"] as? Bool) ?? false
                    let raw = sanitize((contentToString(block["content"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                    let headline: String
                    if isError {
                        headline = raw.isEmpty ? "Tool error" : "Tool error: \(condense(raw))"
                    } else {
                        headline = raw.isEmpty ? "Tool returned" : raw
                    }
                    out.events.append(
                        .init(
                            kind: isError ? .error : .toolResult,
                            text: headline,
                            detail: nil
                        )
                    )
                }
            }

        case "result":
            let isError = (obj["is_error"] as? Bool) ?? false
            let resultText = obj["result"] as? String ?? ""
            out.didError = isError
            out.finalResult = sanitize(resultText)

        default:
            break
        }

        return out
    }

    // MARK: - Friendly tool-call labels

    private static func humanize(toolName: String, input: [String: Any]) -> (String, String?) {
        // Strip mcp__server__ prefix. Split on the literal "__" so the tool name
        // itself can still contain single underscores (e.g. mcp__cua-driver__type_text).
        let stripped: String = {
            if toolName.hasPrefix("mcp__") {
                let parts = toolName.components(separatedBy: "__").filter { !$0.isEmpty }
                if let last = parts.last { return last }
            }
            return toolName
        }()

        switch stripped.lowercased() {
        case let n where n.contains("screenshot"):
            return ("Taking screenshot", nil)
        case let n where n.contains("accessibility") || n.contains("axtree"):
            return ("Reading screen elements", appHint(input))
        case let n where n.contains("click"):
            return ("Clicking", elementHint(input))
        case let n where n.contains("type") && n.contains("text"):
            let snippet = (input["text"] as? String) ?? (input["chars"] as? String) ?? ""
            return ("Typing", snippet.prefix(80).description)
        case let n where n.contains("launch") && n.contains("app"):
            return ("Opening app", input["app"] as? String ?? input["bundle_id"] as? String)
        case let n where n.contains("scroll"):
            return ("Scrolling", nil)
        case let n where n.contains("hotkey") || n.contains("press_key"):
            let keys = (input["keys"] as? [String])?.joined(separator: "+") ?? (input["key"] as? String ?? "")
            return ("Pressing keys", keys)
        case "bash":
            let cmd = (input["command"] as? String) ?? ""
            return ("Running command", cmd)
        case "read":
            return ("Reading file", input["file_path"] as? String)
        case "edit", "write":
            return (stripped == "write" ? "Writing file" : "Editing file", input["file_path"] as? String)
        case "grep":
            return ("Searching files", input["pattern"] as? String)
        case "glob":
            return ("Listing files", input["pattern"] as? String)
        case "webfetch":
            return ("Fetching URL", input["url"] as? String)
        case "websearch":
            return ("Searching the web", input["query"] as? String)
        case "task":
            return ("Delegating to subagent", input["description"] as? String)
        case "todowrite":
            return ("Updating plan", nil)
        default:
            // Fallback: split camel/snake case into words.
            let pretty = humanizeIdentifier(stripped)
            return (pretty, nil)
        }
    }

    private static func humanizeIdentifier(_ s: String) -> String {
        // Split camelCase / PascalCase boundaries: insert a space before an
        // uppercase letter that follows a lowercase one (e.g. "TodoWrite" -> "Todo Write").
        var camelSplit = ""
        var prevWasLower = false
        for ch in s {
            if ch.isUppercase, prevWasLower { camelSplit.append(" ") }
            camelSplit.append(ch)
            prevWasLower = ch.isLowercase
        }
        let withSpaces = camelSplit
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return withSpaces
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func appHint(_ input: [String: Any]) -> String? {
        if let app = input["app"] as? String { return app }
        if let bundle = input["bundle_id"] as? String { return bundle }
        return nil
    }

    private static func elementHint(_ input: [String: Any]) -> String? {
        if let idx = input["element_index"] as? Int { return "element #\(idx)" }
        if let label = input["element_label"] as? String { return label }
        return nil
    }

    private static func contentToString(_ raw: Any?) -> String? {
        if let s = raw as? String { return s }
        if let arr = raw as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return nil
    }

    /// Replaces internal tool-name references with the user-facing brand. The
    /// underlying binary is `cua-driver`; users see "pointer-driver". Both the
    /// tool's own log lines (which travel back via tool_result text) and any
    /// assistant prose that references it get rewritten.
    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "cua-driver", with: "pointer-driver", options: .caseInsensitive)
    }

    private static func condense(_ s: String) -> String {
        let oneline = s.replacingOccurrences(of: "\n", with: " ")
        return oneline.count <= 120 ? oneline : String(oneline.prefix(120)) + "..."
    }
}
