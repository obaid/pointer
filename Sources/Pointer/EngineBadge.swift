import SwiftUI

/// Small read-only pill showing which engine ran a task. Used on orb cards
/// and history rows. Engine identity only — model and reasoning-effort don't
/// surface here to keep the cards compact.
struct EngineBadge: View {
    let engine: RunnerEngine
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: engine.symbolName)
                .font(.system(size: compact ? 8 : 9, weight: .semibold))
            Text(engine.badgeText)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
        }
        .padding(.horizontal, compact ? 5 : 6)
        .padding(.vertical, compact ? 1 : 2)
        .background(
            Capsule()
                .fill(.quaternary.opacity(0.45))
        )
        .foregroundStyle(.secondary)
    }
}

/// Configuration chip in the command bar. Three sections in the menu:
///   • Engine — visible only when 2+ installed.
///   • Model  — engine-specific list. "Default" passes no --model flag.
///   • Reasoning effort — Codex only. "Default" passes no -c flag.
///
/// The chip label collapses unused parts: just "Claude" when both model and
/// effort are at default; "Codex · gpt-5.5 · High" when both are set.
///
/// Hides itself entirely when no engine is installed.
struct ConfigChip: View {
    @Binding var engine: RunnerEngine
    @Binding var modelArg: String?
    @Binding var reasoningEffort: ReasoningEffort?

    var body: some View {
        let installed = RunnerEngine.allCases.filter {
            FileManager.default.isExecutableFile(atPath: $0.locateBinary())
        }
        if installed.isEmpty {
            EmptyView()
        } else {
            Menu {
                if installed.count > 1 {
                    Section("Engine") {
                        ForEach(installed) { e in
                            Button(action: { selectEngine(e) }) {
                                Label {
                                    HStack {
                                        Text(e.displayName)
                                        Spacer()
                                        if engine == e {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                } icon: {
                                    Image(systemName: e.symbolName)
                                }
                            }
                        }
                    }
                }
                Section("Model") {
                    ForEach(engine.availableModels) { model in
                        Button(action: { modelArg = model.cliArg }) {
                            HStack {
                                Text(model.displayName)
                                Spacer()
                                if model.cliArg == modelArg {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                if engine.supportsReasoningEffort {
                    Section("Reasoning effort") {
                        Button(action: { reasoningEffort = nil }) {
                            HStack {
                                Text("Default")
                                Spacer()
                                if reasoningEffort == nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        ForEach(ReasoningEffort.allCases) { effort in
                            Button(action: { reasoningEffort = effort }) {
                                HStack {
                                    Text(effort.displayName)
                                    Spacer()
                                    if reasoningEffort == effort {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                chipLabel
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Engine, model, and reasoning effort for the next task")
        }
    }

    private func selectEngine(_ newEngine: RunnerEngine) {
        engine = newEngine
        // Swap to the saved model preference for the new engine. nil = default.
        modelArg = EnginePreference.preferredModel(for: newEngine)
        // Effort isn't per-engine — but the chip hides it when the new engine
        // doesn't support it, so no need to reset.
    }

    private var chipParts: [String] {
        var parts: [String] = [engine.displayName]
        if let modelArg,
           let model = engine.availableModels.first(where: { $0.cliArg == modelArg }) {
            parts.append(model.displayName)
        }
        if engine.supportsReasoningEffort, let effort = reasoningEffort {
            parts.append(effort.displayName)
        }
        return parts
    }

    private var chipLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: engine.symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text(chipParts.joined(separator: " · "))
                .font(.system(size: 11, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.quaternary.opacity(0.5))
        )
        .foregroundStyle(.primary)
    }
}
