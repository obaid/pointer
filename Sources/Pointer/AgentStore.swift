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
    /// Engine-specific session ID (Claude session_id, Codex thread_id).
    /// Captured from the first stream event. Used to resume the conversation
    /// when the user sends a follow-up reply.
    var sessionId: String?
    /// Which CLI ran this task. Determines the runner + parser used both for
    /// the initial run and any follow-ups. Persisted so history reflects it.
    var engine: RunnerEngine
    /// CLI value passed via --model (Claude) or -m (Codex). nil = use engine default.
    var modelArg: String?
    /// Codex reasoning effort. nil = use Codex's configured default. Always
    /// nil for Claude (no CLI knob exists).
    var reasoningEffort: ReasoningEffort?
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
        engine: RunnerEngine = .claude,
        modelArg: String? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.startedAt = startedAt
        self.state = state
        self.activity = activity
        self.sessionId = sessionId
        self.engine = engine
        self.modelArg = modelArg
        self.reasoningEffort = reasoningEffort
        self.endedAt = endedAt
    }

    /// Custom decoder so older history entries (written before the engine /
    /// model / effort fields existed) still decode — missing fields default
    /// to .claude / nil / nil respectively.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.prompt = try c.decode(String.self, forKey: .prompt)
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        self.state = try c.decode(TaskState.self, forKey: .state)
        self.activity = try c.decode([ActivityEvent].self, forKey: .activity)
        self.sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        self.engine = try c.decodeIfPresent(RunnerEngine.self, forKey: .engine) ?? .claude
        self.modelArg = try c.decodeIfPresent(String.self, forKey: .modelArg)
        self.reasoningEffort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
        self.endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
    }

    var latestActivity: ActivityEvent? { activity.last }
    var canFollowUp: Bool { sessionId != nil }
    var isTerminal: Bool {
        if case .running = state { return false }
        return true
    }

    /// Best-effort detection that the agent finished a turn but is asking
    /// the user a question rather than reporting a complete result. Drives
    /// the amber dot + auto-expand. False negatives are safe; we'd rather
    /// miss a prompt than nag the user when the agent actually finished.
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

    /// Cap on concurrent running agents. New submissions are rejected when
    /// `runningCount` reaches this limit.
    static let maxConcurrent = 5

    /// All tasks currently displayed in the orb stack, most-recent-first.
    /// Removed only on explicit user dismiss — even after a task finishes,
    /// it stays in the stack so the user can read the result and follow up.
    @Published private(set) var tasks: [ActiveTask] = []

    /// At most one task can be expanded at a time. nil = all collapsed.
    @Published var expandedTaskId: UUID? = nil

    /// One-shot signal: AppDelegate sets this to true before showing the command bar
    /// when the user invoked the global voice hotkey. CommandBarView observes it and
    /// auto-starts dictation, then resets the flag.
    @Published var pendingAutoVoice: Bool = false

    private var processes: [UUID: Process] = [:]
    private var handles: [UUID: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - Derived state

    var runningCount: Int {
        tasks.reduce(0) { count, task in
            if case .running = task.state { return count + 1 }
            return count
        }
    }
    var anyRunning: Bool { runningCount > 0 }
    var anyAwaitingReply: Bool { tasks.contains { $0.awaitingReply } }
    var canAcceptNewTask: Bool { runningCount < Self.maxConcurrent }

    func task(id: UUID) -> ActiveTask? { tasks.first { $0.id == id } }

    // MARK: - User actions

    /// Spawn a new agent for `prompt` with `engine` + optional model + optional
    /// reasoning effort. Returns false (no-op) if at capacity. Defaults come
    /// from the saved preferences.
    @discardableResult
    func submit(
        prompt: String,
        engine: RunnerEngine = EnginePreference.current,
        modelArg: String? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard canAcceptNewTask else { return false }

        let resolvedEffort = engine.supportsReasoningEffort ? reasoningEffort : nil
        let new = ActiveTask(
            prompt: trimmed,
            startedAt: Date(),
            engine: engine,
            modelArg: modelArg,
            reasoningEffort: resolvedEffort
        )
        tasks.insert(new, at: 0)
        appendActivity(.init(kind: .info, text: "Starting \(engine.displayName)...", detail: nil), for: new.id)

        let taskId = new.id
        let handle = Task { @MainActor [weak self] in
            await Self.dispatchRun(
                engine: engine,
                prompt: trimmed,
                resumeSessionId: nil,
                modelArg: modelArg,
                reasoningEffort: resolvedEffort,
                taskId: taskId,
                store: self
            )
        }
        handles[taskId] = handle
        return true
    }

    /// Continue task `taskId` with a follow-up reply (resumes the same engine
    /// session, reusing the original task's model + effort selection).
    func followUp(taskId: UUID, reply: String) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = tasks.firstIndex(where: { $0.id == taskId }),
              let sessionId = tasks[idx].sessionId else { return }

        let engine = tasks[idx].engine
        let modelArg = tasks[idx].modelArg
        let reasoningEffort = tasks[idx].reasoningEffort
        tasks[idx].state = .running
        tasks[idx].endedAt = nil
        appendActivity(.init(kind: .info, text: "→ \(trimmed)", detail: nil), for: taskId)

        let handle = Task { @MainActor [weak self] in
            await Self.dispatchRun(
                engine: engine,
                prompt: trimmed,
                resumeSessionId: sessionId,
                modelArg: modelArg,
                reasoningEffort: reasoningEffort,
                taskId: taskId,
                store: self
            )
        }
        handles[taskId] = handle
    }

    /// Picks the right runner for `engine`. Each runner has the same shape:
    /// spawn the CLI, stream its NDJSON, write events back to `store`, finish.
    private static func dispatchRun(
        engine: RunnerEngine,
        prompt: String,
        resumeSessionId: String?,
        modelArg: String?,
        reasoningEffort: ReasoningEffort?,
        taskId: UUID,
        store: AgentStore?
    ) async {
        switch engine {
        case .claude:
            await ClaudeAgentRunner.run(
                prompt: prompt,
                resumeSessionId: resumeSessionId,
                modelArg: modelArg,
                taskId: taskId,
                store: store
            )
        case .codex:
            await CodexAgentRunner.run(
                prompt: prompt,
                resumeSessionId: resumeSessionId,
                modelArg: modelArg,
                reasoningEffort: reasoningEffort,
                taskId: taskId,
                store: store
            )
        }
    }

    /// Terminate the agent process for `taskId` and mark the task cancelled.
    /// Leaves the task in the stack so the user can read what happened.
    func cancel(taskId: UUID) {
        processes[taskId]?.terminate()
        handles[taskId]?.cancel()
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        if case .running = tasks[idx].state {
            tasks[idx].state = .cancelled
            tasks[idx].endedAt = Date()
            HistoryStore.shared.record(tasks[idx])
        }
        appendActivity(.init(kind: .warning, text: "Cancelled", detail: nil), for: taskId)
    }

    func cancelAll() {
        for task in tasks where !task.isTerminal {
            cancel(taskId: task.id)
        }
    }

    /// Remove a task from the stack. Cancels first if it's still running.
    func dismiss(taskId: UUID) {
        if let idx = tasks.firstIndex(where: { $0.id == taskId }), !tasks[idx].isTerminal {
            cancel(taskId: taskId)
        }
        tasks.removeAll { $0.id == taskId }
        processes.removeValue(forKey: taskId)
        handles.removeValue(forKey: taskId)
        if expandedTaskId == taskId { expandedTaskId = nil }
    }

    // MARK: - Runner-facing API

    func registerProcess(_ process: Process, for taskId: UUID) {
        guard tasks.contains(where: { $0.id == taskId }) else { return }
        processes[taskId] = process
    }

    func appendActivity(_ event: ActivityEvent, for taskId: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[idx].activity.append(event)
    }

    func setSessionId(_ id: String, for taskId: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }), tasks[idx].sessionId == nil else { return }
        tasks[idx].sessionId = id
    }

    func finish(taskId: UUID, state: TaskState) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[idx].state = state
        tasks[idx].endedAt = Date()
        processes.removeValue(forKey: taskId)
        handles.removeValue(forKey: taskId)
        HistoryStore.shared.record(tasks[idx])
        // Auto-expand if this task is asking the user something and nothing
        // is currently expanded — so the question is visible immediately.
        if tasks[idx].awaitingReply, expandedTaskId == nil {
            expandedTaskId = taskId
        }
    }
}
