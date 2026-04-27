import SwiftUI

/// The orb — Pointer's primary "is the agent doing something?" surface.
/// Two states: collapsed (a small pill) and expanded (a full activity panel with cancel).
///
/// State note: expansion lives on AgentStore.orbExpanded so AppDelegate can observe and
/// resize the host NSPanel. We never rebuild the hosted view — only its content reacts.
struct OrbView: View {
    @ObservedObject var store: AgentStore
    let onClose: () -> Void

    var body: some View {
        Group {
            if store.orbExpanded {
                ExpandedPanel(store: store, onClose: onClose)
            } else {
                CollapsedPill(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Collapsed pill

private struct CollapsedPill: View {
    @ObservedObject var store: AgentStore

    @State private var pulse = false

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
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 280, height: 56)
        .background(orbBackground)
        .contentShape(Rectangle())
        .onTapGesture { store.orbExpanded = true }
        .onAppear { pulse = store.isRunning }
        .onChange(of: store.isRunning) { _, running in pulse = running }
    }

    private var statusDot: some View {
        ZStack {
            Circle()
                .fill(dotColor.opacity(0.25))
                .frame(width: 22, height: 22)
                .scaleEffect(pulse ? 1.15 : 1.0)
                .animation(store.isRunning ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: pulse)
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
        }
        .frame(width: 24, height: 24)
    }

    private var dotColor: Color {
        guard let task = store.task else { return .secondary }
        switch task.state {
        case .running: return .blue
        case .done: return .green
        case .cancelled: return .orange
        case .failed: return .red
        }
    }

    private var headline: String {
        guard let task = store.task else { return "Pointer" }
        // Always keep the user's prompt visible — status is conveyed by the dot color.
        return task.prompt
    }

    private var subline: String {
        guard let task = store.task else { return "Idle" }
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

// MARK: - Expanded panel

private struct ExpandedPanel: View {
    @ObservedObject var store: AgentStore
    let onClose: () -> Void

    @State private var replyText: String = ""
    @FocusState private var replyFocused: Bool

    private var canReply: Bool {
        guard let task = store.task else { return false }
        if case .done = task.state { return task.canFollowUp }
        if case .failed = task.state { return task.canFollowUp }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if let task = store.task, task.activity.isEmpty {
                            Text("Working...")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 12)
                        } else if let task = store.task {
                            ForEach(task.activity) { event in
                                ActivityRow(event: event).id(event.id)
                            }
                        }
                        if let task = store.task, case .done(let summary) = task.state {
                            ResultBlock(summary: summary).id("__result__")
                        }
                    }
                    .padding(14)
                }
                .onChange(of: store.task?.activity.count ?? 0) { _, _ in
                    if let last = store.task?.activity.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: store.task?.state) { _, state in
                    if case .done = state {
                        withAnimation { proxy.scrollTo("__result__", anchor: .bottom) }
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
            Text(headerText)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button(action: { store.orbExpanded = false }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .help("Collapse")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var headerDotColor: Color {
        guard let task = store.task else { return .secondary }
        switch task.state {
        case .running: return .blue
        case .done: return .green
        case .cancelled: return .orange
        case .failed: return .red
        }
    }

    private var headerText: String {
        store.task?.prompt ?? "Pointer"
    }

    private var footer: some View {
        HStack {
            if store.isRunning {
                Button(role: .destructive) {
                    store.cancel()
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
            if !store.isRunning {
                Button("Dismiss") {
                    store.dismiss()
                    onClose()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var durationLabel: String {
        guard let task = store.task else { return "" }
        let secs = Int(Date().timeIntervalSince(task.startedAt))
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
        store.followUp(reply: trimmed)
        replyText = ""
    }
}

private struct ActivityRow: View {
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

private struct ResultBlock: View {
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

private var orbBackground: some View {
    ZStack {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.regularMaterial)
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 12)
}
