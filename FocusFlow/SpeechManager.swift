import Foundation
import Speech
import AVFoundation

/// Whether hands-free voice runs in THIS process. On a real device: always. On the SIMULATOR we
/// default to text mode, but the sim DOES capture the Mac's microphone and SFSpeechRecognizer works
/// there — so launching with the `VOX_FORCE_VOICE=1` environment variable turns on the real voice
/// path (mic → recognizer → the always-on arm/re-arm lifecycle) for testing off-device. This closes
/// the gap that hid the listener-lifecycle regressions. See docs/qa-voice-testing.md.
enum VoiceEnv {
    static var supported: Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["VOX_FORCE_VOICE"] == "1"
        #else
        return true
        #endif
    }
}

@MainActor
final class SpeechManager: NSObject, ObservableObject {
    // Single process-wide owner of the microphone. The mic and AVAudioSession are
    // one physical/global resource; two SpeechManager instances (one for the Tasks
    // list, one for the Brain Dump sheet) each ran their own AVAudioEngine and each
    // toggled AVAudioSession.setActive(). They deactivated the session out from under
    // each other (armed-but-hears-nothing) and raced installTap/removeTap on the same
    // input hardware, which threw `CreateRecordingTap: (nullptr == Tap())` and hung the
    // app. Enforce exactly one instance so there is one engine, one tap, one session owner.
    static let shared = SpeechManager()

    @Published var transcript = ""
    @Published var isRecording = false
    @Published var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published var micGranted = false

    // Called after silenceTimeout seconds of no new words (with semantic extension). Set before startRecording().
    var onSilenceDetected: (() -> Void)?

    // MARK: Single-owner always-on listening
    // Home and the Tasks list both want hands-free listening, but there is ONE mic/session. Two
    // per-view arm/re-arm loops raced it during navigation, thrashing the audio session (rapid
    // deactivate/reactivate spawned route-change interruptions that restarted the engine — the
    // "listening but nothing captured" bug). This coordinator guarantees exactly one owner: a new
    // owner supersedes the old via a generation counter, so stale arms/callbacks bail. See §24.
    private var listenGeneration = 0
    private(set) var listenOwner: String?
    private var armWork: DispatchWorkItem?

    // True in the last 500ms before auto-stop fires — use to show a visual countdown.
    @Published var autoStopImminent: Bool = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var silenceWorkItem: DispatchWorkItem?
    private var silenceExtended = false   // true after one semantic extension

    // Continuation waiting for isFinal — set by finalize(), resolved by the recognition callback.
    private var finalizeContinuation: CheckedContinuation<String, Never>?
    private var didFinalize = false
    private var interruptionObserver: NSObjectProtocol?
    private var silenceTimeout: TimeInterval {
        switch UserDefaults.standard.string(forKey: "silenceTimeout") {
        case "fast":    return 1.5
        case "relaxed": return 4.0
        default:        return 2.5
        }
    }
    private let semanticExtension: TimeInterval = 1.0
    private let countdownLeadTime: TimeInterval = 0.5

    // Private so `SpeechManager.shared` is the only instance — see the note above.
    private override init() {
        super.init()
        recognizer?.delegate = self
        authStatus = SFSpeechRecognizer.authorizationStatus()
        // Seed mic permission from the system so a fresh instance (e.g. the always-on
        // Tasks-list listener) can record once permission was granted anywhere in the app.
        // Without this, micGranted stayed false on every instance except the one that
        // called requestAuthorization(), so those mics failed with micNotAuthorized.
        if #available(iOS 17.0, *) {
            micGranted = AVAudioApplication.shared.recordPermission == .granted
        }
    }

    func requestAuthorization() async {
        authStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        if #available(iOS 17, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
    }

    func startRecording() throws {
        // Only a DEFINITIVE denial should surface the "Open Settings" alert. During launch the
        // async authorization request may not have resolved yet (authStatus .notDetermined or
        // micGranted not re-published), and the always-on listener re-arms on a timer — treating
        // that transient state as a denial was reprompting for permissions the user already
        // granted (bug 5). Distinguish real denial from "not ready yet".
        let micDenied: Bool = {
            if #available(iOS 17.0, *) { return AVAudioApplication.shared.recordPermission == .denied }
            return AVAudioSession.sharedInstance().recordPermission == .denied
        }()
        if authStatus == .denied || authStatus == .restricted { throw SpeechError.notAuthorized }
        if micDenied { throw SpeechError.micNotAuthorized }
        guard let recognizer else { throw SpeechError.unavailable }
        // Authorized-but-not-yet-resolved: retryable, never an alert.
        guard authStatus == .authorized, micGranted else { throw SpeechError.notReady }

        stopRecording()
        transcript = ""

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechError.sessionFailed(error.localizedDescription)
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Do not force on-device — the model may not be downloaded on a fresh device,
        // causing silent empty transcripts (kAFAssistantErrorDomain 1110). Let the
        // system choose server-side as a fallback when on-device is unavailable.
        request = req

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }

        let node = engine.inputNode
        // Always clear any stale tap before installing. A tap can linger when the
        // engine was only *paused* (audio interruption) rather than stopped, or when a
        // previous start() failed after the tap was installed. installTap() on an
        // already-tapped node throws `CreateRecordingTap: (nullptr == Tap())`, an
        // uncaught ObjC exception that hangs the app. removeTap on an untapped bus is a
        // documented no-op, so this is always safe.
        node.removeTap(onBus: 0)
        let format = node.inputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            node.removeTap(onBus: 0)
            throw SpeechError.engineFailed(error.localizedDescription)
        }

        isRecording = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.transcript {
                        self.transcript = text
                        // Don't reset silence timer once finalize() is waiting — we already called endAudio()
                        if !text.isEmpty && self.finalizeContinuation == nil {
                            self.resetSilenceTimer()
                        }
                    }
                    // isFinal delivers the most accurate transcript — resolve finalize() if waiting
                    if result.isFinal, !self.didFinalize, let cont = self.finalizeContinuation {
                        self.didFinalize = true
                        self.finalizeContinuation = nil
                        cont.resume(returning: text)
                        self.stopRecording()
                    }
                }
                if let error {
                    let e = error as NSError
                    if !(e.domain == "kAFAssistantErrorDomain" && e.code == 1110) {
                        // Unblock finalize() on error too — deliver whatever transcript we have
                        if !self.didFinalize, let cont = self.finalizeContinuation {
                            self.didFinalize = true
                            self.finalizeContinuation = nil
                            cont.resume(returning: self.transcript)
                        }
                        self.cancelSilenceTimer()
                        self.stopRecording()
                    }
                }
            }
        }
    }

    // Signals end of audio input and waits for the recognizer's isFinal result before returning.
    // Falls back to the current partial transcript after 2 seconds if isFinal never arrives.
    func finalize() async -> String {
        cancelSilenceTimer()
        didFinalize = false
        return await withCheckedContinuation { continuation in
            self.finalizeContinuation = continuation
            self.request?.endAudio()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, !self.didFinalize else { return }
                self.didFinalize = true
                self.finalizeContinuation = nil
                let t = self.transcript
                continuation.resume(returning: t)
                self.stopRecording()
            }
        }
    }

    func stopRecording() {
        cancelSilenceTimer()
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if engine.isRunning {
            engine.stop()
        }
        // Remove the tap unconditionally, NOT only when isRunning. handleAudioInterruption
        // pauses the engine on .began (Siri / a call), which leaves isRunning == false but
        // the tap still installed. Guarding removeTap behind isRunning meant the next
        // startRecording() skipped it, then installTap() crashed with
        // `CreateRecordingTap: (nullptr == Tap())`. removeTap on an untapped bus is a no-op.
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Start (or take over) always-on listening for `owner`. Supersedes any current owner so the
    /// Home <-> Tasks hand-off can never run two arm loops against the one mic. `onFinal` fires with
    /// the finalized transcript after each utterance; listening auto-continues for the same owner
    /// until `stopListening(as:)` or another owner takes over. Safe to call repeatedly (idempotent
    /// re-arm): each call is a fresh generation, and stale timers/callbacks bail on the generation.
    func listen(as owner: String, onFinal: @escaping (String) -> Void) {
        listenGeneration &+= 1
        let gen = listenGeneration
        listenOwner = owner
        onSilenceDetected = { [weak self] in
            guard let self, gen == self.listenGeneration else { return }
            onFinal(self.transcript)
            // Auto-continue for the same owner unless onFinal changed ownership (navigated / spoke).
            if gen == self.listenGeneration { self.armNext(gen: gen, attempt: 0) }
        }
        armNext(gen: gen, attempt: 0)
    }

    /// Resign listening if `owner` still holds it (no-op if a newer owner already took over).
    func stopListening(as owner: String) {
        guard listenOwner == owner else { return }
        listenGeneration &+= 1        // invalidate any pending arm / onSilence callback
        listenOwner = nil
        armWork?.cancel(); armWork = nil
        stopRecording()
    }

    private func armNext(gen: Int, attempt: Int) {
        armWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.listenGeneration else { return }
            do {
                try self.startRecording()
                BDLog.speech.log("listen[\(self.listenOwner ?? "?", privacy: .public)]: armed (attempt \(attempt))")
            } catch {
                BDLog.speech.error("listen arm failed (\(attempt)): \(error.localizedDescription, privacy: .public)")
                if attempt < 2 { self.armNext(gen: gen, attempt: attempt + 1) }
            }
        }
        armWork = work
        // Small settle so a superseding owner's stopListening can cancel this before it fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        if type == .began {
            // Siri or a phone call has taken the audio session.
            // Pause the engine without tearing it down so we can resume cleanly.
            if engine.isRunning { engine.pause() }
            cancelSilenceTimer()
        } else if type == .ended {
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard options.contains(.shouldResume), isRecording else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
                resetSilenceTimer()
            } catch {
                // Session could not be restarted — finalize with whatever we captured
                onSilenceDetected?()
            }
        }
    }

    private func resetSilenceTimer() {
        silenceWorkItem?.cancel()
        autoStopImminent = false
        silenceExtended = false
        scheduleStop(after: silenceTimeout)
    }

    private func scheduleStop(after delay: TimeInterval) {
        silenceWorkItem?.cancel()

        // Countdown visual fires countdownLeadTime before the actual stop.
        let countdownDelay = max(0, delay - countdownLeadTime)
        let countdownItem = DispatchWorkItem { [weak self] in
            self?.autoStopImminent = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + countdownDelay, execute: countdownItem)

        let stopItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Semantic extension: if transcript doesn't end with terminal punctuation and we haven't
            // extended yet, give the user one more second to finish their sentence.
            let t = self.transcript.trimmingCharacters(in: .whitespaces)
            let endsWithPunctuation = t.last.map { ".!?,;".contains($0) } ?? false
            if !endsWithPunctuation && !t.isEmpty && !self.silenceExtended {
                self.silenceExtended = true
                self.autoStopImminent = false
                self.scheduleStop(after: self.semanticExtension)
            } else {
                self.autoStopImminent = false
                self.onSilenceDetected?()
            }
        }
        silenceWorkItem = stopItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: stopItem)
    }

    private func cancelSilenceTimer() {
        silenceWorkItem?.cancel()
        silenceWorkItem = nil
        autoStopImminent = false
        silenceExtended = false
    }
}

extension SpeechManager: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer,
                                      availabilityDidChange available: Bool) {
        Task { @MainActor in if !available { self.stopRecording() } }
    }
}

enum SpeechError: LocalizedError {
    case notAuthorized, micNotAuthorized, unavailable, notReady
    case sessionFailed(String), engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:         return "Speech recognition is off. Go to Settings → Voxdump → Speech Recognition and enable it."
        case .micNotAuthorized:      return "Microphone is off. Go to Settings → Voxdump → Microphone and enable it."
        case .unavailable:           return "Speech recognition is not available on this device."
        case .notReady:              return "Still getting the microphone ready…"
        case .sessionFailed(let m):  return "Audio session error: \(m)"
        case .engineFailed(let m):   return "Audio engine error: \(m)"
        }
    }
}
