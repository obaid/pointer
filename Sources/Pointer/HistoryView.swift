import SwiftUI

/// Read-only browser for past tasks. Two-pane layout:
///   • Left: list of tasks, most recent first.
///   • Right: detail of the selected task — prompt, full activity feed,
///     final result, and metadata (status / when / how long).
///
/// This window can be open at the same time as the live orb. Selecting a row
/// here never affects the active task.
struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @State private var selectedId: UUID?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 280)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            if selectedId == nil { selectedId = store.entries.first?.id }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(store.entries.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider().opacity(0.4)
            if store.entries.isEmpty {
                emptyState
            } else {
                List(selection: $selectedId) {
                    ForEach(store.entries) { entry in
                        HistoryRow(task: entry)
                            .tag(Optional(entry.id))
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No tasks yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedId, let task = store.entries.first(where: { $0.id == id }) {
            HistoryDetail(task: task)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select a task to view its activity.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Sidebar row

private struct HistoryRow: View {
    let task: ActiveTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusDot
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.prompt)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    EngineBadge(engine: task.engine, compact: true)
                    Text(task.startedAt, style: .relative)
                        .font(.system(size: 10))
                    Text("·").foregroundStyle(.tertiary)
                    Text(stateLabel)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
    }

    private var dotColor: Color {
        switch task.state {
        case .running: return .blue
        case .done: return .green
        case .cancelled: return .orange
        case .failed: return .red
        }
    }

    private var stateLabel: String {
        switch task.state {
        case .running: return "running"
        case .done: return "done"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }
}

// MARK: - Detail pane

private struct HistoryDetail: View {
    let task: ActiveTask

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(task.activity) { event in
                        ActivityRow(event: event)
                    }
                    if case .done(let summary) = task.state {
                        ResultBlock(summary: summary)
                            .padding(.top, 4)
                    }
                    if case .failed(let msg) = task.state {
                        ResultBlock(summary: msg)
                            .padding(.top, 4)
                    }
                }
                .padding(16)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.prompt)
                .font(.system(size: 14, weight: .semibold))
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Label(stateLabel, systemImage: stateIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(stateColor)
                Text(task.startedAt, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(task.startedAt, style: .time)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let duration {
                    Text("·").foregroundStyle(.tertiary)
                    Text(duration)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateLabel: String {
        switch task.state {
        case .running: return "Running"
        case .done: return "Done"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    private var stateIcon: String {
        switch task.state {
        case .running: return "circle.dotted"
        case .done: return "checkmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var stateColor: Color {
        switch task.state {
        case .running: return .blue
        case .done: return .green
        case .cancelled: return .orange
        case .failed: return .red
        }
    }

    private var duration: String? {
        guard let end = task.endedAt else { return nil }
        let secs = Int(end.timeIntervalSince(task.startedAt))
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60
        let s = secs % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }
}
