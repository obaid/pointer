import SwiftUI

/// Small read-only pill showing which engine ran a task. Used on orb cards
/// and history rows.
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

/// Interactive engine picker for the command bar. Hides itself entirely when
/// only one engine is installed — no point making the user pick from a menu
/// of one. Selection is bound; CommandBarView mirrors it back to the
/// EnginePreference UserDefaults key on submit.
struct EnginePicker: View {
    @Binding var selection: RunnerEngine

    var body: some View {
        let installed = RunnerEngine.allCases.filter {
            FileManager.default.isExecutableFile(atPath: $0.locateBinary())
        }
        // No choice to surface — keep the bar uncluttered.
        if installed.count <= 1 {
            EmptyView()
        } else {
            Menu {
                ForEach(installed) { engine in
                    Button(action: { selection = engine }) {
                        Label {
                            HStack {
                                Text(engine.displayName)
                                Spacer()
                                if engine == selection {
                                    Image(systemName: "checkmark")
                                }
                            }
                        } icon: {
                            Image(systemName: engine.symbolName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: selection.symbolName)
                        .font(.system(size: 10, weight: .semibold))
                    Text(selection.displayName)
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
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose which engine handles this task")
        }
    }
}
