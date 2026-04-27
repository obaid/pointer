import Foundation
import AVFoundation
import Speech
import SwiftUI

/// Captures microphone audio and streams transcripts via Apple's on-device
/// `SpeechAnalyzer` (macOS 26+). The first run downloads the locale's transcription
/// model into AssetInventory; subsequent runs are instant.
///
/// Concurrency note: AVAudioEngine taps fire on a high-priority IO thread, so the
/// tap captures only Sendable locals (the converter + the stream continuation) —
/// it never touches main-actor state directly.
@MainActor
final class Dictator: ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var transcript: String = ""
    @Published private(set) var statusMessage: String? = nil // "Preparing model...", errors, etc.

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzeTask: Task<Void, Never>?

    func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    func start() async {
        guard !isRecording else { return }
        NSLog("🎤 Dictator.start")
        statusMessage = "Preparing..."
        transcript = ""

        do {
            try await ensureAuthorization()
            NSLog("🎤 authorized — beginning session")
            try await beginSession()
            isRecording = true
            statusMessage = nil
            NSLog("🎤 session running")
        } catch {
            NSLog("🎤 start failed: \(error.localizedDescription)")
            statusMessage = error.localizedDescription
            await teardown()
        }
    }

    func stop() async {
        guard isRecording else { return }
        // Flip UI state first and tear down the audio engine synchronously so no
        // more audio is captured. The analyzer finalize step (which can take 2–3s
        // to flush the model) runs in the background — by the time it returns,
        // the user is already submitting / editing the transcript.
        isRecording = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputBuilder?.finish()
        inputBuilder = nil
        let lingering = analyzer
        analyzer = nil
        analyzeTask?.cancel()
        analyzeTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let lingering {
            Task.detached { await lingering.cancelAndFinishNow() }
        }
    }

    // MARK: - Permissions

    private func ensureAuthorization() async throws {
        NSLog("🎤 speech.authStatus=\(SFSpeechRecognizer.authorizationStatus().rawValue) mic.authStatus=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        NSLog("🎤 speech.requestAuth=\(speech.rawValue)")
        guard speech == .authorized else {
            throw DictationError.message("Speech recognition permission denied. Enable it in System Settings → Privacy & Security → Speech Recognition.")
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        NSLog("🎤 mic.requestAccess=\(mic)")
        guard mic else {
            throw DictationError.message("Microphone permission denied. Enable it in System Settings → Privacy & Security → Microphone.")
        }
    }

    // MARK: - Session

    private func beginSession() async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw DictationError.message("No supported transcription locale for \(Locale.current.identifier).")
        }
        // Custom config tuned for command-bar-style dictation:
        //  .volatileResults — emit partials as the user speaks (not just final segments).
        //  .fastResults     — shorter look-ahead window for lower latency at a tiny accuracy cost.
        // .progressiveTranscription preset enables volatileResults but not fastResults; the latter
        // is the difference between "shows up in ~1.5s" and "shows up almost as I speak".
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )

        NSLog("🎤 locale=\(locale.identifier)")

        // First-launch model download.
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            NSLog("🎤 downloading speech model")
            statusMessage = "Downloading speech model..."
            try await req.downloadAndInstall()
            NSLog("🎤 model installed")
        } else {
            NSLog("🎤 no asset install needed")
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.message("No compatible audio format for the speech model.")
        }

        let (inputSequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.inputBuilder = builder

        // Consume transcript results. The transcriber emits one Result per *segment*
        // — not one cumulative transcript. With volatile partials enabled we get
        // many updates for the same in-progress segment, then `isFinal=true` once
        // the segment is locked. After that, a new segment starts. We must
        // accumulate finalized segments and render volatile partials on top.
        resultsTask = Task { [weak self] in
            var stable = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        stable += text
                        let snapshot = stable
                        NSLog("🎤 final: '\(text)' → total: '\(snapshot)'")
                        await MainActor.run { self?.transcript = snapshot }
                    } else {
                        let preview = stable + text
                        await MainActor.run { self?.transcript = preview }
                    }
                }
                NSLog("🎤 results stream ended")
            } catch is CancellationError {
                NSLog("🎤 results cancelled (expected)")
            } catch {
                NSLog("🎤 results error: \(error.localizedDescription)")
                await MainActor.run { self?.statusMessage = error.localizedDescription }
            }
        }

        // Start audio capture.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let recordingFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: recordingFormat, to: analyzerFormat) else {
            throw DictationError.message("Couldn't build audio converter.")
        }
        let ratio = analyzerFormat.sampleRate / recordingFormat.sampleRate

        // Capture only Sendable values for the audio thread closure.
        // AsyncStream.Continuation is a struct; we just capture by value. Calling
        // yield() after finish() is a no-op, so this is safe across teardown.
        let continuation = builder
        let tapCounter = TapCounter()
        let yieldBuffer: @Sendable (AVAudioPCMBuffer) -> Void = { pcm in
            continuation.yield(AnalyzerInput(buffer: pcm))
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            let count = tapCounter.bump()
            // Pull-based convert(to:error:withInputFrom:) is the only variant that
            // supports sample-rate conversion. We feed exactly one input buffer per
            // tap and then return .noDataNow — the converter keeps its filter state
            // alive across calls. Earlier we used .endOfStream and the converter
            // stayed in a finalized state after the first call, producing 0 frames.
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: outCapacity) else {
                if count <= 3 { NSLog("🎤 tap[\(count)]: failed to allocate outBuffer") }
                return
            }
            var fed = false
            var convError: NSError?
            converter.convert(to: outBuffer, error: &convError) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if count <= 3 || count % 50 == 0 {
                NSLog("🎤 tap[\(count)]: in=\(buffer.frameLength) out=\(outBuffer.frameLength) err=\(convError?.localizedDescription ?? "nil")")
            }
            if convError == nil, outBuffer.frameLength > 0 {
                yieldBuffer(outBuffer)
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
        NSLog("🎤 audio engine started, recordingFormat=\(recordingFormat) analyzerFormat=\(analyzerFormat)")

        analyzeTask = Task {
            do {
                _ = try await analyzer.analyzeSequence(inputSequence)
                NSLog("🎤 analyzeSequence finished cleanly")
            } catch {
                NSLog("🎤 analyzeSequence threw: \(error.localizedDescription)")
            }
        }
    }

    private func teardown() async {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputBuilder?.finish()
        inputBuilder = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        analyzer = nil
        analyzeTask?.cancel()
        analyzeTask = nil
        resultsTask?.cancel()
        resultsTask = nil
    }
}

enum DictationError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

/// Lock-free counter shared with the audio thread to throttle log spam.
final class TapCounter: @unchecked Sendable {
    private var value: Int = 0
    private let lock = NSLock()
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
