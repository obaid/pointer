import Foundation

/// Shared utilities for stream-event parsers (Claude, Codex). Keeps the
/// engine-specific parsers thin by centralizing the cross-cutting concerns:
/// brand sanitization, length condensing, friendly tool-call labels, and
/// warning-glyph cleanup.
enum ParseHelpers {

    /// Replaces internal tool-name references with the user-facing brand.
    /// The underlying binary is `cua-driver`; users see "pointer-driver".
    /// Both tool log lines (returned via tool_result text) and assistant
    /// prose that references it get rewritten.
    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "cua-driver", with: "pointer-driver", options: .caseInsensitive)
    }

    /// Strips a leading ⚠/❗ glyph (with optional VS16 emoji selector + spaces)
    /// from each line. Used for successful tool results, where these glyphs
    /// are hint markers rather than actual errors.
    static func stripLeadingWarningGlyphs(_ s: String) -> String {
        let warningChars: Set<Character> = ["⚠", "❗", "❕"]
        let lines = s.components(separatedBy: "\n").map { line -> String in
            let leading = line.prefix { $0.isWhitespace }
            var rest = line.dropFirst(leading.count)
            guard let first = rest.first, warningChars.contains(first) else { return line }
            rest = rest.dropFirst()
            if rest.first == "\u{FE0F}" { rest = rest.dropFirst() }
            while let c = rest.first, c.isWhitespace { rest = rest.dropFirst() }
            return String(leading) + String(rest)
        }
        return lines.joined(separator: "\n")
    }

    /// Single-line, length-clamped version of multi-line tool output. Used
    /// when surfacing detail text in the activity row.
    static func condense(_ s: String) -> String {
        let oneline = s.replacingOccurrences(of: "\n", with: " ")
        return oneline.count <= 120 ? oneline : String(oneline.prefix(120)) + "..."
    }

    /// Maps a raw tool name + input dict to a friendly "(label, optional detail)"
    /// pair shown in the activity feed. Both Claude (`tool_use.name`) and
    /// Codex (`mcp_tool_call` shaped as `mcp__server__tool`) feed in here.
    static func humanize(toolName: String, input: [String: Any]) -> (String, String?) {
        // Strip mcp__server__ prefix. Split on the literal "__" so the tool
        // name itself can still contain single underscores.
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
            return (humanizeIdentifier(stripped), nil)
        }
    }

    /// Splits camelCase / snake_case / kebab-case identifiers into Title Case.
    private static func humanizeIdentifier(_ s: String) -> String {
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
}
