import SwiftUI

/// The orb stack — Pointer's primary "what are my agents up to?" surface.
/// Each running task gets its own OrbCard, stacked top-down with most recent
/// on top. At most one card is expanded at a time; the rest stay visible as
/// collapsed pills so the user always knows what's running.
struct OrbView: View {
    @ObservedObject var store: AgentStore
    let onDismiss: (UUID) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                ForEach(store.tasks) { task in
                    OrbCard(store: store, task: task, onDismiss: { onDismiss(task.id) })
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .scale(scale: 0.9).combined(with: .opacity)
                        ))
                }
            }
            .padding(.vertical, 0)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: store.tasks.map(\.id))
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: store.expandedTaskId)
    }
}

/// One task in the stack. Switches between collapsed pill and expanded panel
/// based on `store.expandedTaskId`. Single-expand semantics — clicking a
/// collapsed card sets the expanded id, which collapses any other.
private struct OrbCard: View {
    @ObservedObject var store: AgentStore
    let task: ActiveTask
    let onDismiss: () -> Void

    var isExpanded: Bool { store.expandedTaskId == task.id }

    var body: some View {
        Group {
            if isExpanded {
                ExpandedCard(store: store, task: task, onDismiss: onDismiss)
            } else {
                CollapsedCard(store: store, task: task, onDismiss: onDismiss)
            }
        }
    }
}

// MARK: - Collapsed card

private struct CollapsedCard: View {
    @ObservedObject var store: AgentStore
    let task: ActiveTask
    let onDismiss: () -> Void

    @State private var pulse = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            EngineBadge(engine: task.engine, compact: true)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 360, height: 56)
        .background(orbBackground)
        .contentShape(Rectangle())
        .onTapGesture { store.expandedTaskId = task.id }
        .onHover { hovering = $0 }
        .onAppear { pulse = shouldPulse }
        .onChange(of: shouldPulse) { _, p in pulse = p }
    }

    /// Hover-only X overlays the chevron — quick dismiss without expanding.
    private var trailing: some View {
        ZStack {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 0 : 1)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help(task.isTerminal ? "Dismiss" : "Cancel & dismiss")
        }
        .frame(width: 22, height: 22)
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    private var shouldPulse: Bool {
        if case .running = task.state { return true }
        return task.awaitingReply
    }

    private var statusDot: some View {
        ZStack {
            Circle()
                .fill(dotColor.opacity(0.25))
                .frame(width: 22, height: 22)
                .scaleEffect(pulse ? 1.15 : 1.0)
                .animation(shouldPulse ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: pulse)
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
        }
        .frame(width: 24, height: 24)
    }

    private var dotColor: Color {
        if task.awaitingReply { return .yellow }
        switch task.state {
        case .running: return .blue
        case .done: return .green
        case .cancelled: return .orange
        case .failed: return .red
        }
    }

    private var headline: String { task.prompt }

    private var subline: String {
        switch task.state {
        case .running:
            return task.latestActivity?.text ?? "Thinking..."
        case .done(let summary):
            return condense(summary)
        case .cancelled:
            return "Stopped"
        case .failed(let msg):
            return condense(msg)
        }
    }

    private func condense(_ s: String) -> String {
        let oneline = s.replacingOccurrences(of: "\n", with: " ")
        return oneline.count <= 80 ? oneline : String(oneline.prefix(80)) + "..."
    }
}

// MARK: - Expanded card

private struct ExpandedCard: View {
    @ObservedObject var store: AgentStore
    let task: ActiveTask
    let onDismiss: () -> Void

    @State private var replyText: String = ""
    @FocusState private var replyFocused: Bool

    private var canReply: Bool {
        if case .done = task.state { return task.canFollowUp }
        if case .failed = task.state { return task.canFollowUp }
        return false
    }

    private var isRunning: Bool {
        if case .running = task.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if task.activity.isEmpty {
                            Text("Working...")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 12)
                        } else {
                            ForEach(task.activity) { event in
                                ActivityRow(event: event).id(event.id)
                            }
                        }
                        if case .done(let summary) = task.state {
                            ResultBlock(summary: summary).id("__result_\(task.id)")
                        }
                    }
                    .padding(14)
                }
                .onChange(of: task.activity.count) { _, _ in
                    if let last = task.activity.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: task.state) { _, state in
                    if case .done = state {
                        withAnimation { proxy.scrollTo("__result_\(task.id)", anchor: .bottom) }
                    }
                }
            }
            if canReply {
                Divider().opacity(0.3)
                replyBar
            }
            Divider().opacity(0.3)
            footer
        }
        .frame(width: 360, height: 480)
        .background(orbBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(headerDotColor)
                .frame(width: 8, height: 8)
            Text(task.prompt)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer()
            EngineBadge(engine: task.engine, compact: true)
            Button(action: { store.expandedTaskId = nil }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .help("Collapse")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .help(isRunning ? "Cancel & dismiss" : "Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var headerDotColor: Color {
        if task.awaitingReply { return .yellow }
        switch task.state {
        case .running: return .blue
        case .done: return .green
        case .cancelled: return .orange
        case .failed: return .red
        }
    }

    private var footer: some View {
        HStack {
            if isRunning {
                Button(role: .destructive) {
                    store.cancel(taskId: task.id)
                } label: {
                    Label("Cancel", systemImage: "stop.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            } else {
                Text(durationLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var durationLabel: String {
        let secs = Int((task.endedAt ?? Date()).timeIntervalSince(task.startedAt))
        return "Took \(secs)s"
    }

    private var replyBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Reply or ask a follow-up...", text: $replyText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($replyFocused)
                .onSubmit(sendReply)
            Button(action: sendReply) {
                let isEmpty = replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.18))
        .onAppear { replyFocused = true }
    }

    private func sendReply() {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.followUp(taskId: task.id, reply: trimmed)
        replyText = ""
    }
}

// MARK: - Activity row + Result block (shared with HistoryView)

struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: event.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(rowColor)
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.text)
                    .font(.system(size: 12, weight: weightFor(event.kind)))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, design: monoFor(event.kind) ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    private var rowColor: Color {
        switch event.kind {
        case .info: return .secondary
        case .message: return .accentColor
        case .toolCall: return .blue
        case .toolResult: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func weightFor(_ kind: ActivityEvent.Kind) -> Font.Weight {
        switch kind {
        case .toolCall: return .semibold
        default: return .regular
        }
    }

    private func monoFor(_ kind: ActivityEvent.Kind) -> Bool {
        switch kind {
        case .toolCall, .toolResult, .error: return true
        default: return false
        }
    }
}

struct ResultBlock: View {
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RESULT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.25))
        )
        .padding(.top, 4)
    }
}

// MARK: - Shared chrome

var orbBackground: some View {
    ZStack {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.regularMaterial)
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 12)
}
