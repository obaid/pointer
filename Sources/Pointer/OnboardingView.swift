import SwiftUI

struct OnboardingView: View {
    @ObservedObject var checker: PrereqsChecker
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 14) {
                StepRow(
                    title: "AI engine",
                    subtitle: "Powers the agents that handle your tasks.",
                    status: checker.state.aiEngine,
                    primaryActionLabel: actionLabel(for: checker.state.aiEngine, missing: "Install"),
                    primaryAction: {
                        if let url = URL(string: "https://claude.com/product/claude-code") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
                StepRow(
                    title: "Computer access",
                    subtitle: "Lets Pointer click, type, and read your apps.",
                    status: checker.state.computer,
                    primaryActionLabel: actionLabel(for: checker.state.computer, missing: "Set up"),
                    primaryAction: {
                        Task { _ = await checker.installComputerAccess() }
                    }
                )
                StepRow(
                    title: "Voice input (optional)",
                    subtitle: "Dictate tasks instead of typing them.",
                    status: checker.state.voice,
                    primaryActionLabel: actionLabel(for: checker.state.voice, missing: "Allow"),
                    primaryAction: {
                        Task { await checker.requestVoice() }
                    }
                )
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 520)
        .background(.regularMaterial)
        .task { await checker.runAllChecks() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.85), Color.purple.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 56, height: 56)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 16, y: 6)
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
            }
            Text("Welcome to Pointer")
                .font(.system(size: 22, weight: .semibold))
            Text("Let's get a few things in place before your first task.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Re-check") { Task { await checker.runAllChecks() } }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Continue", action: onFinish)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!checker.state.allReady)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func actionLabel(for status: PrereqsChecker.CheckStatus, missing: String) -> String {
        switch status {
        case .missing: return missing
        case .failed: return "Retry"
        default: return ""
        }
    }
}

private struct StepRow: View {
    let title: String
    let subtitle: String
    let status: PrereqsChecker.CheckStatus
    let primaryActionLabel: String
    let primaryAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            statusBadge
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                if case .failed(let msg) = status {
                    Text(msg)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .lineLimit(2)
                }
            }
            Spacer()
            if !primaryActionLabel.isEmpty {
                Button(primaryActionLabel, action: primaryAction)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .unknown:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.tertiary)
        case .checking:
            ProgressView().controlSize(.small)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .missing, .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }
}
