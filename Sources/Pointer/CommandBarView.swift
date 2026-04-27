import SwiftUI

struct CommandBarView: View {
    @ObservedObject var store: AgentStore
    let onSubmit: () -> Void
    var onContentHeightChange: ((CGFloat) -> Void)? = nil

    @State private var text: String = ""
    @StateObject private var dictator = Dictator()
    @FocusState private var focused: Bool
    /// Briefly true when the user tries to submit at the concurrency cap.
    /// Drives the "all slots full" inline warning.
    @State private var capacityWarning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                TextField("Ask Pointer to do something...", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .lineLimit(1...8)
                    .focused($focused)

                MicButton(dictator: dictator)
                    .padding(.top, 1)
            }
            if let status = dictator.statusMessage {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(dictator.isRecording ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                    .padding(.leading, 30)
                    .lineLimit(2)
            }
            if store.runningCount > 0 || capacityWarning {
                slotIndicator
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .frame(width: 560)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { height in
            onContentHeightChange?(height)
        }
        .onAppear {
            // Defer to the next runloop tick — when the bar is shown the
            // borderless window hasn't quite finished becoming key, so a
            // synchronous focus assignment is dropped before AppKit installs
            // the field as first responder.
            DispatchQueue.main.async { focused = true }
            // Handle the case where the bar is shown for the first time *with*
            // pendingAutoVoice already true (onChange may not fire then).
            if store.pendingAutoVoice {
                store.pendingAutoVoice = false
                Task { await dictator.start() }
            }
        }
        .onChange(of: dictator.transcript) { _, newValue in
            // Live-replace the prompt text with the latest partial transcript
            // while recording. After stop, the field keeps the final value.
            if dictator.isRecording { text = newValue }
        }
        .onChange(of: store.pendingAutoVoice) { _, requested in
            if requested {
                store.pendingAutoVoice = false
                if !dictator.isRecording {
                    text = ""
                    Task { await dictator.start() }
                }
            }
        }
        .onKeyPress(.return) {
            // Shift+Return inserts a newline (let TextField handle it).
            // Plain Return submits.
            if NSEvent.modifierFlags.contains(.shift) { return .ignored }
            submit()
            return .handled
        }
        .onKeyPress(.escape) {
            // First Esc while typing/dictating → clear & stop.
            // Second Esc (or first if empty) → close the window.
            if dictator.isRecording {
                Task { await dictator.stop() }
                return .handled
            }
            if !text.isEmpty {
                text = ""
                return .handled
            }
            onSubmit() // reuses the close-window callback
            return .handled
        }
        .onDisappear {
            if dictator.isRecording {
                Task { await dictator.stop() }
            }
        }
    }

    private func submit() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard store.canAcceptNewTask else {
            // Capacity reached — flash a warning and keep the bar open so the
            // user sees it. Auto-clears in 3s.
            withAnimation { capacityWarning = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { capacityWarning = false }
            }
            return
        }
        if dictator.isRecording {
            Task { await dictator.stop() }
        }
        store.submit(prompt: prompt)
        text = ""
        onSubmit()
    }

    /// Five small pips + an N/5 label. Fills left-to-right with the current
    /// running-task count. Flashes orange when the user hits the cap.
    private var slotIndicator: some View {
        let n = store.runningCount
        let max = AgentStore.maxConcurrent
        let warning = capacityWarning
        let labelColor: AnyShapeStyle = warning
            ? AnyShapeStyle(Color.orange)
            : AnyShapeStyle(.tertiary)
        return HStack(spacing: 5) {
            HStack(spacing: 4) {
                ForEach(0..<max, id: \.self) { i in
                    Circle()
                        .fill(i < n ? Color.accentColor : Color.secondary.opacity(0.22))
                        .frame(width: 5, height: 5)
                }
            }
            Text(warning
                 ? "All \(max) slots full — finish or cancel one to launch another"
                 : "\(n)/\(max) agents active")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(labelColor)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 30)
        .padding(.top, 2)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 80
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MicButton: View {
    @ObservedObject var dictator: Dictator
    @State private var pulse: Bool = false

    var body: some View {
        Button(action: toggle) {
            ZStack {
                Circle()
                    .fill(dictator.isRecording ? Color.red.opacity(0.18) : .clear)
                    .frame(width: 32, height: 32)
                    .scaleEffect(pulse ? 1.18 : 1.0)
                    .animation(
                        dictator.isRecording
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .default,
                        value: pulse
                    )
                Image(systemName: dictator.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(dictator.isRecording ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                    .padding(8)
                    .background(Circle().fill(dictator.isRecording ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.quaternary)))
            }
        }
        .buttonStyle(.plain)
        .help(dictator.isRecording ? "Stop dictation" : "Dictate")
        .onChange(of: dictator.isRecording) { _, recording in
            pulse = recording
        }
    }

    private func toggle() {
        Task { await dictator.toggle() }
    }
}
