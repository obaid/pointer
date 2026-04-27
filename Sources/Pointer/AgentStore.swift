import SwiftUI
import Combine

/// A single human-readable line in the activity feed.
struct ActivityEvent: Identifiable, Equatable, Codable {
    let id: UUID
    let timestamp: Date
    let kind: Kind
    let text: String
    let detail: String?

    init(id: UUID = UUID(), timestamp: Date = Date(), kind: Kind, text: String, detail: String?) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
        self.detail = detail
    }

    enum Kind: String, Equatable, Codable {
        case info        // setup / boilerplate
        case message     // assistant prose
        case toolCall    // a tool invocation
        case toolResult  // a tool's response
        case warning
        case error
    }

    var symbolName: String {
        switch kind {
        case .info: return "circle.dotted"
        case .message: return "text.bubble"
        case .toolCall: return "wrench.and.screwdriver"
        case .toolResult: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}

enum TaskState: Equatable, Codable {
    case running
    case done(summary: String)
    case cancelled
    case failed(message: String)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case running, done, cancelled, failed }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .running:
            try c.encode(Kind.running, forKey: .kind)
        case .done(let s):
            try c.encode(Kind.done, forKey: .kind)
            try c.encode(s, forKey: .value)
        case .cancelled:
            try c.encode(Kind.cancelled, forKey: .kind)
        case .failed(let m):
            try c.encode(Kind.failed, forKey: .kind)
            try c.encode(m, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .running: self = .running
        case .done: self = .done(summary: try c.decode(String.self, forKey: .value))
        case .cancelled: self = .cancelled
        case .failed: self = .failed(message: try c.decode(String.self, forKey: .value))
        }
    }
}

struct ActiveTask: Identifiable, Codable {
    let id: UUID
    let prompt: String
    let startedAt: Date
    var state: TaskState
    var activity: [ActivityEvent]
    /// Claude session ID, captured from the first stream event. Used to resume the
    /// conversation when the user sends a follow-up reply.
    var sessionId: String?
    /// Last time the task transitioned to a terminal state. Used for the
    /// duration column in History; nil while still running.
    var endedAt: Date?

    init(
        id: UUID = UUID(),
        prompt: String,
        startedAt: Date,
        state: TaskState = .running,
        activity: [ActivityEvent] = [],
        sessionId: String? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.startedAt = startedAt
        self.state = state
        self.activity = activity
        self.sessionId = sessionId
        self.endedAt = endedAt
    }

    var latestActivity: ActivityEvent? { activity.last }
    var canFollowUp: Bool { sessionId != nil }
    var isTerminal: Bool {
        if case .running = state { return false }
        return true
    }

    /// Best-effort detection that the agent finished a turn but is asking
    /// the user a question rather than reporting a complete result. Used to
    /// switch the orb's status dot to amber + auto-expand the panel.
    /// Heuristic — false negatives are safe; we'd rather miss a prompt than
    /// nag the user when the agent actually finished.
    var awaitingReply: Bool {
        guard canFollowUp else { return false }
        guard case .done(let summary) = state else { return false }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let lower = trimmed.lowercased()
        let cues = [
            "should i ", "would you like", "do you want", "want me to",
            "shall i ", "let me know", "please confirm", "please clarify",
            "could you confirm", "could you clarify", "which would you",
        ]
        return cues.contains { lower.contains($0) }
    }
}

@MainActor
final class AgentStore: ObservableObject {
    static let shared = AgentStore()

    @Published private(set) var task: ActiveTask?

    /// Whether the orb is expanded into the full panel. UI-only state; lives here so
    /// AppDelegate can observe via Combine and resize the NSPanel without rebuilding the
    /// hosted SwiftUI view.
    @Published var orbExpanded: Bool = false

    /// One-shot signal: AppDelegate sets this to true before showing the command bar
    /// when the user invoked the global voice hotkey. CommandBarView observes it and
    /// auto-starts dictation, then resets the flag.
    @Published var pendingAutoVoice: Bool = false

    /// True while a task is in flight. Drives menu bar animation + orb visibility.
    var isRunning: Bool {
        guard let t = task else { return false }
        if case .running = t.state { return true }
        return false
    }

    private var activeProcess: Process?
    private var runHandle: Task<Void, Never>?

    private init() {}

    func submit(prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel anything in flight.
        if isRunning { cancel() }

        let new = ActiveTask(prompt: trimmed, startedAt: Date())
        task = new
        appendActivity(.init(kind: .info, text: "Starting agent...", detail: nil))

        let taskId = new.id
        runHandle = Task { @MainActor [weak self] in
            await ClaudeAgentRunner.run(prompt: trimmed, resumeSessionId: nil, taskId: taskId, store: self)
        }
    }

    /// Continue the current task with a follow-up message in the same Claude session.
    func followUp(reply: String) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var current = task,
              let sessionId = current.sessionId
        else { return }

        // Mark as running again; keep the activity log so the user sees the full thread.
        current.state = .running
        current.endedAt = nil
        task = current

        appendActivity(.init(kind: .info, text: "→ \(trimmed)", detail: nil))

        let taskId = current.id
        runHandle = Task { @MainActor [weak self] in
            await ClaudeAgentRunner.run(prompt: trimmed, resumeSessionId: sessionId, taskId: taskId, store: self)
        }
    }

    func setSessionId(_ id: String, for taskId: UUID) {
        guard var t = task, t.id == taskId, t.sessionId == nil else { return }
        t.sessionId = id
        task = t
    }

    func cancel() {
        activeProcess?.terminate()
        runHandle?.cancel()
        if var t = task, case .running = t.state {
            t.state = .cancelled
            t.endedAt = Date()
            task = t
        }
        appendActivity(.init(kind: .warning, text: "Cancelled", detail: nil))
        if let t = task { HistoryStore.shared.record(t) }
    }

    func dismiss() {
        guard !isRunning else { return }
        task = nil
        orbExpanded = false
    }

    // MARK: - Runner-facing API

    func registerProcess(_ process: Process, for taskId: UUID) {
        guard task?.id == taskId else { return }
        activeProcess = process
    }

    func appendActivity(_ event: ActivityEvent, for taskId: UUID? = nil) {
        guard var t = task, taskId == nil || t.id == taskId else { return }
        t.activity.append(event)
        task = t
    }

    func finish(taskId: UUID, state: TaskState) {
        guard var t = task, t.id == taskId else { return }
        t.state = state
        t.endedAt = Date()
        task = t
        activeProcess = nil
        HistoryStore.shared.record(t)
        // If the agent is asking the user something and the orb is collapsed,
        // pop it open so the question is visible. Doesn't fire if the user
        // already has the panel expanded.
        if t.awaitingReply, !orbExpanded {
            orbExpanded = true
        }
    }
}
