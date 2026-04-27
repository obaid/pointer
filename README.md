# Pointer

A native macOS menu-bar agent. You give it a task in plain English (typed or dictated), it drives your Mac to get it done — clicking, typing, reading the screen — and streams what it's doing into a small floating "orb" in the top-right corner.

Pointer is a thin SwiftUI front-end on top of **Claude Code** — the LLM agent does the reasoning, and Pointer wires it up to the Mac (screenshot, accessibility tree, click, type, hotkey, launch app, …) so it can actually take action. The app shells out to `claude -p --output-format stream-json` and parses the NDJSON event stream into the activity feed.

## Requirements

- **macOS 26.0** or later (uses the new Speech framework's `SpeechAnalyzer` for on-device dictation)
- **Xcode 26** / Swift 6 toolchain (any version that ships the macOS 26 SDK)
- **Claude Code CLI** installed and authenticated — install instructions: <https://docs.claude.com/en/docs/claude-code>
- A microphone (optional — only if you want voice input)

Pointer auto-installs its computer-access helper during the first-run onboarding flow — no manual setup required.

## Quick start

```bash
git clone https://github.com/<your-username>/pointer.git
cd pointer
swift run Pointer
```

That's it. The first launch:

1. Drops a status-bar icon (no Dock icon — Pointer runs as an "accessory" app).
2. Walks you through three onboarding steps:
   - **AI engine** — verifies `claude` is installed and runs.
   - **Computer access** — installs the helper that lets Pointer click, type, and read your apps (one click).
   - **Voice input** *(optional)* — requests Microphone + Speech Recognition permission.
3. Use **New Task...** from the menu, or press ⌘N when the menu is open, to summon the command bar.

## Using it

- **Command bar** — type a prompt and hit Return. Shift+Return inserts a newline. Esc clears or closes.
- **Mic button** — click to dictate. Words stream into the field as you speak. Click again (or Esc) to stop.
- **Orb** — appears top-right while a task is running. Click to expand and see the activity feed. Cancel from the expanded panel.
- **Follow-ups** — once a task completes, the expanded orb shows a reply field that resumes the same Claude session (`claude -r <session_id>`).

## Architecture

```
Sources/Pointer/
├── PointerApp.swift          # @main, AppDelegate, window/panel plumbing
├── AgentStore.swift          # @MainActor ObservableObject — single-task state
├── CommandBarView.swift      # Spotlight-style input
├── OrbView.swift             # Top-right floating activity panel
├── OnboardingView.swift      # First-run setup
├── Prereqs.swift             # Detects + installs prerequisites at first run
├── ClaudeBinary.swift        # Locates the `claude` CLI on $PATH
├── StubRunner.swift          # Spawns claude -p, streams NDJSON
├── StreamEventParser.swift   # NDJSON → ActivityEvent + tool-name humanizer
├── Dictator.swift            # SpeechAnalyzer + AVAudioEngine wrapper
├── HotkeyMonitor.swift       # Global fn-hold hotkey (currently disabled)
└── Info.plist                # Embedded into the binary via -sectcreate
```

### Why NSHostingView and not NSHostingController

The command bar grows vertically as the user types or dictates. We tried `NSHostingController.sizingOptions = [.preferredContentSize]` first — it stack-overflowed in a layout feedback loop with the multi-line `TextField`. Current approach: a SwiftUI `PreferenceKey` reports content height up to AppDelegate, which calls `setFrame(.., animate: false)` once per change. See `PointerApp.swift::resizeCommandWindow`.

### Why `animationBehavior = .none` on every custom window

Default AppKit window animations (order, key, frame) crashed the app twice via `-[_NSWindowTransformAnimation dealloc]` during autorelease pool drain. The orb panel and the command bar window both disable system animations.

## Voice input internals

- `SpeechTranscriber` with `[.volatileResults, .fastResults]` for low-latency progressive transcription.
- `AVAudioEngine` input tap at the device's native format (typically 48kHz Float32), converted on-the-fly to the analyzer's preferred format (16kHz Int16) via `AVAudioConverter` in pull-mode with `.noDataNow` to preserve the SRC filter state across buffers.
- Results are accumulated by **segment**: each `isFinal=true` result locks a segment and appends it; volatile partials only preview the in-progress segment on top of locked segments.

The first dictation triggers a one-time on-device model download via `AssetInventory.assetInstallationRequest`.

## Permissions

Pointer asks for these macOS permissions:

| Permission | When | Why |
|---|---|---|
| Microphone | First mic click or onboarding "Allow" | Capture audio for dictation |
| Speech Recognition | Same | Run Apple's on-device transcription model |
| Accessibility | First time the agent drives another app | Read other apps' UI elements and synthesize click/keystroke events |

The microphone and speech-recognition usage strings are embedded into the binary's `__TEXT,__info_plist` section via a linker flag in `Package.swift`.

## Development

Build:
```bash
swift build                   # debug
swift build -c release        # release
```

Run from CLI (auto-builds):
```bash
swift run Pointer
```

Tail the app log:
```bash
swift run Pointer 2>&1 | tee /tmp/pointer.log
```

The runner emits structured logs prefixed `🎤` (dictation) and `🤖` (agent) — handy for debugging the audio pipeline or the NDJSON stream.

## Status

Single-task v1. Multi-agent (multiple concurrent CLI instances, e.g., Claude + Codex + Gemini in parallel) is on the roadmap but not yet wired up. The fn-hold global hotkey is implemented but disabled by default — uncomment three lines in `PointerApp.applicationDidFinishLaunching` to re-enable.

## License

MIT.
