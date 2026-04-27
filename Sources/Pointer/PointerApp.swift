import SwiftUI
import AppKit
import Combine

@main
struct PointerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = AgentStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(store: store, openCommandBar: {
                AppDelegate.shared?.showCommandBar()
            })
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// MenuBarExtra label with a `.variableColor` shimmer while a task is running.
struct MenuBarLabel: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        Image(systemName: "cursorarrow.rays")
            .symbolEffect(.variableColor.iterative.reversing, isActive: store.isRunning)
    }
}

struct MenuBarMenu: View {
    @ObservedObject var store: AgentStore
    let openCommandBar: () -> Void

    var body: some View {
        Button("New Task...", action: openCommandBar)
            .keyboardShortcut("n")
        if store.isRunning {
            Button("Cancel current task") { store.cancel() }
                .keyboardShortcut(".", modifiers: .command)
        }
        Divider()
        Button("Re-run setup...") { AppDelegate.shared?.showOnboarding() }
        Button("Quit Pointer") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    private var commandWindow: KeyableWindow?
    private var orbWindow: KeyableOrbPanel?
    private var onboardingWindow: NSWindow?

    private let prereqs = PrereqsChecker()
    private let hotkeys = HotkeyMonitor()
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            await prereqs.runAllChecks()
            if !prereqs.state.allReady {
                showOnboarding()
            }
        }
        observeStore()
        // fn-hold global hotkey is wired up but disabled — re-enable when we
        // want it back. The HotkeyMonitor + auto-voice plumbing in AgentStore
        // and CommandBarView remain functional, just not invoked.
        // hotkeys.onTrigger = { [weak self] in
        //     self?.showCommandBar(autoStartVoice: true)
        // }
        // hotkeys.start()
    }

    // MARK: - Store observation: drive orb visibility

    private func observeStore() {
        AgentStore.shared.$task
            .receive(on: DispatchQueue.main)
            .sink { [weak self] task in
                self?.reconcileOrb(task: task)
            }
            .store(in: &cancellables)

        AgentStore.shared.$orbExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                guard let self else { return }
                self.positionOrb()
                if expanded {
                    // Becoming key lets the in-panel text field receive keystrokes
                    // for follow-up replies. .nonactivatingPanel keeps the user's
                    // foreground app from being deactivated.
                    self.orbWindow?.makeKey()
                }
            }
            .store(in: &cancellables)
    }

    private func reconcileOrb(task: ActiveTask?) {
        guard task != nil else {
            hideOrb()
            return
        }
        showOrb()
        // No auto-dismiss: user needs to read the result. Orb persists until they
        // explicitly dismiss it or submit another task.
    }

    // MARK: - Command bar

    func showCommandBar(autoStartVoice: Bool = false) {
        if autoStartVoice {
            AgentStore.shared.pendingAutoVoice = true
        }
        NSApp.activate(ignoringOtherApps: true)
        if let w = commandWindow {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        // System shadow renders on the rectangular window bounds and produces a
        // dark rectangular halo around our rounded SwiftUI card. SwiftUI draws
        // its own shadow on the rounded path instead.
        window.hasShadow = false
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Disable AppKit window animations. Their dealloc path has hit us with
        // SIGSEGV when the window is reordered/torn down before the animation
        // completes (see crash forensics).
        window.animationBehavior = .none

        // Manual height tracking. We DELIBERATELY don't use
        // NSHostingController.sizingOptions = [.preferredContentSize] — that
        // recurses with our flexible TextField (windowDidLayout → preferredSize
        // change → setFrame → windowDidLayout → ...) and stack-overflows.
        // Instead, CommandBarView reports its rendered content height via a
        // callback and we resize the window once per change.
        let host = TransparentHostingView(
            rootView: CommandBarView(
                store: AgentStore.shared,
                onSubmit: { [weak self] in
                    self?.commandWindow?.orderOut(nil)
                },
                onContentHeightChange: { [weak self] height in
                    self?.resizeCommandWindow(toHeight: height)
                }
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 80)
        window.contentView = host
        window.center()
        commandWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func resizeCommandWindow(toHeight height: CGFloat) {
        guard let window = commandWindow else { return }
        let clamped = max(64, min(height, 360))
        let current = window.frame
        // Avoid ping-ponging on sub-pixel deltas.
        if abs(current.height - clamped) < 0.5 { return }
        // Keep the window's top edge stable so the bar grows downward.
        let newOrigin = NSPoint(x: current.origin.x, y: current.origin.y + (current.height - clamped))
        let newFrame = NSRect(origin: newOrigin, size: NSSize(width: current.width, height: clamped))
        window.setFrame(newFrame, display: true, animate: false)
    }

    // MARK: - Orb

    private func showOrb() {
        if orbWindow == nil { orbWindow = makeOrbWindow() }
        positionOrb()
        orbWindow?.orderFrontRegardless()
    }

    private func hideOrb() {
        orbWindow?.orderOut(nil)
        AgentStore.shared.orbExpanded = false
    }

    /// Builds the orb panel exactly once. SwiftUI inside reacts to AgentStore.orbExpanded;
    /// AppDelegate only resizes the panel to match. The hosting view is never rebuilt.
    private func makeOrbWindow() -> KeyableOrbPanel {
        let panel = KeyableOrbPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // shadow drawn by SwiftUI
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.animationBehavior = .none // see crash forensics

        let host = NSHostingView(
            rootView: OrbView(
                store: AgentStore.shared,
                onClose: { [weak self] in
                    AgentStore.shared.dismiss()
                    self?.hideOrb()
                }
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 480)
        panel.contentView = host
        return panel
    }

    /// Resizes and re-anchors the orb panel for the current expand state.
    /// No animation — see crash forensics in feedback memory.
    private func positionOrb() {
        guard let panel = orbWindow, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let expanded = AgentStore.shared.orbExpanded
        let size: NSSize = expanded ? NSSize(width: 360, height: 480) : NSSize(width: 280, height: 56)
        let rightInset: CGFloat = 16
        let topInset: CGFloat = 12
        let origin = NSPoint(
            x: f.maxX - size.width - rightInset,
            y: f.maxY - size.height - topInset
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    // MARK: - Onboarding

    func showOnboarding() {
        if let w = onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        let host = NSHostingView(
            rootView: OnboardingView(
                checker: prereqs,
                onFinish: { [weak self, weak window] in
                    window?.close()
                    self?.onboardingWindow = nil
                }
            )
        )
        window.contentView = host
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// NSHostingView that aggressively asserts a transparent backing. Default
/// NSHostingView creates an opaque CALayer that bleeds through the rounded
/// SwiftUI card as a dark rectangular halo. We override isOpaque, clear the
/// layer's background color on every update, and disable subview clipping so
/// SwiftUI shadows can extend past the host bounds.
final class TransparentHostingView<V: View>: NSHostingView<V> {
    required init(rootView: V) {
        super.init(rootView: rootView)
        configureTransparency()
    }
    @objc required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTransparency()
    }

    private func configureTransparency() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.masksToBounds = false
    }

    override var isOpaque: Bool { false }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.masksToBounds = false
    }
}

/// Borderless window that can become key/main so its hosted text field receives keystrokes.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// NSPanel for the orb. `.nonactivatingPanel` style keeps the user's foreground app
/// active when the orb is shown; overriding `canBecomeKey` lets us still take
/// keyboard focus on demand (e.g. when the reply field is visible).
final class KeyableOrbPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
