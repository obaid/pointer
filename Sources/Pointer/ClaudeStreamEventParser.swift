import Foundation

/// One pass of stream-parsing output, regardless of which engine produced it.
/// Both ClaudeStreamEventParser and CodexStreamEventParser populate this shape.
struct ParseOutput {
    var events: [ActivityEvent] = []
    var finalResult: String? = nil
    var didError: Bool = false
    var sessionId: String? = nil
}

/// Parses one NDJSON line emitted by `claude -p --output-format stream-json`.
///
/// Stream schema reference (subset we care about):
///   {"type":"system","subtype":"init",...}
///   {"type":"assistant","message":{"content":[{"type":"text","text":"..."}]}}
///   {"type":"assistant","message":{"content":[{"type":"tool_use","id":"...","name":"...","input":{...}}]}}
///   {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"...","content":...}]}}
///   {"type":"result","subtype":"success","result":"...","is_error":false,...}
enum ClaudeStreamEventParser {
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
                    let (label, detail) = ParseHelpers.humanize(toolName: raw, input: input)
                    out.events.append(.init(
                        kind: .toolCall,
                        text: ParseHelpers.sanitize(label),
                        detail: detail.map(ParseHelpers.sanitize)
                    ))
                case "text":
                    let trimmed = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        out.events.append(.init(kind: .message, text: ParseHelpers.sanitize(trimmed), detail: nil))
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
                    let raw = ParseHelpers.sanitize(
                        (contentToString(block["content"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    let headline: String
                    if isError {
                        headline = raw.isEmpty ? "Tool error" : "Tool error: \(ParseHelpers.condense(raw))"
                    } else {
                        // Successful results sometimes carry inline ⚠ hint text.
                        // The green checkmark already conveys success — drop the
                        // alarm glyph so it doesn't read like a failure.
                        let cleaned = ParseHelpers.stripLeadingWarningGlyphs(raw)
                        headline = cleaned.isEmpty ? "Tool returned" : cleaned
                    }
                    out.events.append(.init(
                        kind: isError ? .error : .toolResult,
                        text: headline,
                        detail: nil
                    ))
                }
            }

        case "result":
            let isError = (obj["is_error"] as? Bool) ?? false
            let resultText = obj["result"] as? String ?? ""
            out.didError = isError
            out.finalResult = ParseHelpers.sanitize(resultText)

        default:
            break
        }

        return out
    }

    /// Claude's tool_result content is either a plain string or an array of
    /// {type, text} blocks. Codex tool results look different and live in
    /// CodexStreamEventParser, so this stays here.
    private static func contentToString(_ raw: Any?) -> String? {
        if let s = raw as? String { return s }
        if let arr = raw as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return nil
    }
}
