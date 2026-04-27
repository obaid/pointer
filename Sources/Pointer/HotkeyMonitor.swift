import AppKit

/// Watches the global modifier-flag stream for a fn-key hold and fires
/// `onTrigger` after a debounce window.
///
/// macOS calls fn the "globe" key (.function flag). The user can configure
/// the system fn-tap action in Settings → Keyboard ("Press 🌐 key to..."). To
/// avoid colliding with that on a quick tap, we require the key to be held
/// for `triggerHoldSeconds` before we fire — and we never fire a second
/// time until the key is released.
///
/// Permission: NSEvent global keyboard monitoring requires Input Monitoring
/// in System Settings → Privacy & Security. The first call to
/// `addGlobalMonitorForEvents` triggers a system prompt; if the user denies
/// it, the monitor is silently inert until they grant it (and restart).
@MainActor
final class HotkeyMonitor {
    var onTrigger: (() -> Void)?

    /// How long fn must be held before the trigger fires. 0.15s is long enough
    /// to dodge an accidental tap, short enough to feel like a hotkey.
    private let triggerHoldSeconds: TimeInterval = 0.15

    private var monitor: Any?
    private var pressStartedAt: TimeInterval?
    private var firedThisHold = false

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Modifier-flag events arrive on the main thread already, but be
            // explicit so the closure stays @Sendable-clean.
            DispatchQueue.main.async { self?.handle(event) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pressStartedAt = nil
        firedThisHold = false
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags
        let fnDown = flags.contains(.function)
        // Only treat fn alone as a trigger — fn+arrow / fn+letter combos
        // produce the same .function flag and we don't want to swallow them.
        let onlyFn = flags.intersection([.command, .shift, .option, .control]).isEmpty

        if fnDown && onlyFn {
            if pressStartedAt == nil {
                let started = ProcessInfo.processInfo.systemUptime
                pressStartedAt = started
                firedThisHold = false
                DispatchQueue.main.asyncAfter(deadline: .now() + triggerHoldSeconds) { [weak self] in
                    guard let self else { return }
                    // Still the same hold and not fired yet → fire.
                    if self.pressStartedAt == started, !self.firedThisHold {
                        self.firedThisHold = true
                        self.onTrigger?()
                    }
                }
            }
        } else {
            // fn released (or another modifier joined it) — reset.
            pressStartedAt = nil
            firedThisHold = false
        }
    }
}
