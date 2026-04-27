import SwiftUI
import Combine

/// A single human-readable line in the activity feed.
struct ActivityEvent: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let kind: Kind
    let text: String
    let detail: String?

    enum Kind: Equatable {
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

enum TaskState: Equatable {
    case running
    case done(summary: String)
    case cancelled
    case failed(message: String)
}

struct ActiveTask: Identifiable {
    let id = UUID()
    let prompt: String
    let startedAt: Date
    var state: TaskState = .running
    var activity: [ActivityEvent] = []
    /// Claude session ID, captured from the first stream event. Used to resume the
    /// conversation when the user sends a follow-up reply.
    var sessionId: String? = nil

    var latestActivity: ActivityEvent? { activity.last }
    var canFollowUp: Bool { sessionId != nil }
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
        if var t = task {
            if case .running = t.state {
                t.state = .cancelled
                task = t
            }
        }
        appendActivity(.init(kind: .warning, text: "Cancelled", detail: nil))
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
        task = t
        activeProcess = nil
    }
}
