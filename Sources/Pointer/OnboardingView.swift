import SwiftUI

struct OnboardingView: View {
    @ObservedObject var checker: PrereqsChecker
    let onFinish: () -> Void

    /// Picked default engine for new tasks. Initialized from the saved
    /// preference and saved back on Continue.
    @State private var defaultEngine: RunnerEngine = EnginePreference.current

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 14) {
                AIEngineStep(checker: checker, defaultEngine: $defaultEngine)
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
        // Keep the @State default in sync with available engines: if the
        // user uninstalls the saved-preference engine, fall back to the first
        // installed one so Continue saves something useful.
        .onChange(of: checker.state.installedEngines) { _, installed in
            if !installed.contains(defaultEngine), let first = installed.first {
                defaultEngine = first
            }
        }
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
            Button("Continue") {
                EnginePreference.current = defaultEngine
                onFinish()
            }
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

/// AI engine step. Lists all supported engines; user installs at least one
/// and (when 2+ are installed) picks a default for new tasks.
private struct AIEngineStep: View {
    @ObservedObject var checker: PrereqsChecker
    @Binding var defaultEngine: RunnerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                statusBadge.frame(width: 22).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI engines").font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(spacing: 6) {
                ForEach(RunnerEngine.allCases) { engine in
                    EngineRow(
                        engine: engine,
                        status: checker.state.engines[engine] ?? .unknown,
                        isDefault: defaultEngine == engine,
                        canBeDefault: (checker.state.engines[engine] ?? .unknown).isResolved,
                        onPickDefault: { defaultEngine = engine }
                    )
                }
            }
            .padding(.leading, 36)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
    }

    private var subtitle: String {
        switch checker.state.installedEngines.count {
        case 0: return "Install at least one to run Pointer."
        case 1: return "Pointer is ready. Install the other to switch between them per task."
        default: return "Both installed — pick which one runs new tasks by default."
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if checker.state.installedEngines.isEmpty {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

private struct EngineRow: View {
    let engine: RunnerEngine
    let status: PrereqsChecker.CheckStatus
    let isDefault: Bool
    let canBeDefault: Bool
    let onPickDefault: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon.frame(width: 16)
            Image(systemName: engine.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(engine.displayName)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.30))
        )
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .ok:
            if canBeDefault {
                Button(action: onPickDefault) {
                    HStack(spacing: 4) {
                        Image(systemName: isDefault ? "circle.inset.filled" : "circle")
                            .foregroundStyle(isDefault ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        Text("Default")
                            .font(.system(size: 11))
                            .foregroundStyle(isDefault ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    }
                }
                .buttonStyle(.plain)
                .disabled(isDefault)
                .help(isDefault ? "This is your default engine" : "Use \(engine.displayName) by default")
            }
        case .missing:
            Button("Install") {
                if let url = engine.installURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        case .failed(let msg):
            VStack(alignment: .trailing, spacing: 2) {
                Button("Install") {
                    if let url = engine.installURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                Text(msg.prefix(40))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        case .checking:
            ProgressView().controlSize(.small)
        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .unknown:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .checking:
            ProgressView().controlSize(.small)
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing, .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
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
