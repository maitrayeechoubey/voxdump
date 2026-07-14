import SwiftUI
import SwiftData
import Speech
import AVFoundation
import OSLog

// MARK: - Sheet container

struct BrainDumpSheet: View {
    var onComplete: () -> Void = {}
    var onCommand: (ParsedDump.VoiceCommand) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var speech = SpeechManager()
    @StateObject private var ai = AIParsingManager()
    @StateObject private var speaker = SpeakManager()
    private let synth = AVSpeechSynthesizer()

    @State private var state: DumpState = {
        #if targetEnvironment(simulator)
        return .ready
        #else
        return .starting
        #endif
    }()
    @State private var textMode: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()
    @State private var manualInput = ""
    @State private var permissionAlert: SpeechError?
    /// Extracted task title -> the existing task title it duplicates, for the review-card warning.
    @State private var duplicateOf: [String: String] = [:]
    /// A pending bulk-destructive command awaiting confirmation (irreversible wipes).
    @State private var pendingBulkDelete: PendingBulkDelete?
    /// True while listening for a spoken yes/no on a bulk-delete confirmation (device only).
    @State private var confirmVoiceActive = false

    private enum DumpState {
        case starting, ready, recording, processing, reviewing([ParsedTask])
    }

    private enum BulkDeleteKind { case all, completed, completeAndClear }
    private struct PendingBulkDelete: Identifiable {
        let id = UUID()
        let kind: BulkDeleteKind
        let count: Int
        private var noun: String { count == 1 ? "task" : "tasks" }
        var title: String {
            switch kind {
            case .all:              return "Delete all \(count) \(noun)?"
            case .completeAndClear: return "Complete and clear all \(count) \(noun)?"
            case .completed:        return "Delete \(count) completed \(noun)?"
            }
        }
        var confirmLabel: String {
            switch kind {
            case .all:              return "Delete All"
            case .completeAndClear: return "Complete & Clear"
            case .completed:        return "Delete Completed"
            }
        }
        var spokenPrompt: String {
            switch kind {
            case .all:              return "Delete all \(count) \(noun)? Say yes to confirm, or no to cancel."
            case .completeAndClear: return "Complete and clear all \(count) \(noun)? Say yes to confirm, or no to cancel."
            case .completed:        return "Delete \(count) completed \(noun)? Say yes to confirm, or no to cancel."
            }
        }
    }

    var body: some View {
        ZStack {
            Color.bdBg.ignoresSafeArea()
            switch state {
            case .starting:
                StartingView()
            case .ready:
                ReadyView(
                    authStatus: speech.authStatus,
                    micGranted: speech.micGranted,
                    textMode: $textMode,
                    manualInput: $manualInput,
                    onStart: startRecording,
                    onProcessText: { processTranscript(manualInput) },
                    onCancel: { dismiss() }
                )
            case .recording:
                RecordingView(speech: speech, onStop: stopAndProcess)
            case .processing:
                ProcessingView(mode: ai.parsingMode)
            case .reviewing(let tasks):
                CardReviewView(
                    tasks: tasks,
                    duplicateOf: duplicateOf,
                    speech: speech,
                    voiceEnabled: !textMode,
                    onKeep: { save($0) },
                    onFinish: { onComplete() }
                )
            }
        }
        .onAppear {
            print("[braindump:sheet] BrainDumpSheet appeared — requesting mic and starting recording")
            Task { @MainActor in
                await speech.requestAuthorization()
                #if !targetEnvironment(simulator)
                startRecording()
                #endif
            }
        }
        .alert("Permission Required", isPresented: Binding(
            get: { permissionAlert != nil },
            set: { if !$0 { permissionAlert = nil } }
        )) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Use Text Instead") { textMode = true }
        } message: {
            Text(permissionAlert?.errorDescription ?? "")
        }
        // Explicit confirmation for irreversible bulk deletes (a voice command alone must not
        // wipe the list). Requires a deliberate tap; Cancel leaves everything untouched.
        .confirmationDialog(
            pendingBulkDelete?.title ?? "",
            isPresented: Binding(
                get: { pendingBulkDelete != nil },
                // Any dismissal (Cancel button or tapping outside) clears the pending delete and
                // closes the sheet without deleting. Confirm runs performBulkDelete first.
                set: { if !$0 { confirmVoiceActive = false; speech.stopRecording(); pendingBulkDelete = nil; dismiss() } }
            ),
            titleVisibility: .visible,
            presenting: pendingBulkDelete
        ) { pending in
            Button(pending.confirmLabel, role: .destructive) { performBulkDelete(pending.kind) }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This can't be undone.")
        }
        // Fully hands-free: once the spoken confirmation prompt finishes, listen for "yes"/"no".
        .onChange(of: speaker.isSpeaking) { _, speaking in
            if !speaking { armConfirmMic() }
        }
    }

    private func startRecording() {
        print("[braindump:mic] startRecording called — auth=\(speech.authStatus.rawValue) micGranted=\(speech.micGranted)")
        do {
            speech.onSilenceDetected = stopAndProcess
            try speech.startRecording()
            print("[braindump:mic] recording started successfully")
            withAnimation { state = .recording }
        } catch let error as SpeechError {
            permissionAlert = error
            // Land on .ready (not .starting) so the alert's "Use Text Instead" button
            // actually reaches a screen where textMode is consulted.
            withAnimation { state = .ready }
        } catch {
            permissionAlert = .engineFailed(error.localizedDescription)
            withAnimation { state = .ready }
        }
    }

    private func stopAndProcess() {
        guard case .recording = state else { return }
        withAnimation { state = .processing }
        Task { @MainActor in
            // Wait for the recognizer's isFinal result (up to 2s) rather than snapping
            // a partial transcript that may be incomplete or empty.
            let t = await speech.finalize()
            guard !t.trimmingCharacters(in: .whitespaces).isEmpty else {
                // Never silently drop back to ready — on-device recognition can come back
                // empty (model not downloaded, noise, recognizer error) and the user needs
                // to know their note wasn't captured, not just see the screen reset.
                speak("I didn't catch that. Try again, or switch to text instead.")
                withAnimation { state = .ready }
                return
            }
            processTranscript(t)
        }
    }

    private func speak(_ text: String) {
        let utt = AVSpeechUtterance(string: text)
        utt.rate = 0.52
        utt.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(utt)
    }

    private func processTranscript(_ text: String) {
        guard !TranscriptFilter.isStopOnly(text) else {
            manualInput = ""
            withAnimation { state = .ready }
            return
        }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        withAnimation { state = .processing }
        Task {
            do {
                let result = try await ai.parse(transcript: text)
                NSLog("[voxdump:parse] intent/command=%@ rawTranscript='%@'", String(describing: result.command), text)
                if let command = result.command {
                    await MainActor.run { executeCommand(command) }
                } else {
                    // Deduplicate by normalized title to guard against LLM repetition
                    var seen = Set<String>()
                    let unique = result.tasks.filter { task in
                        let key = task.title.lowercased().trimmingCharacters(in: .whitespaces)
                        return seen.insert(key).inserted
                    }
                    print("[braindump:parsing] extracted \(result.tasks.count) tasks → \(unique.count) unique")
                    await MainActor.run {
                        if unique.isEmpty {
                            // Never silently drop back to ready — tell the user nothing was captured.
                            speak("I didn't catch any tasks. Try again.")
                            withAnimation { state = .ready }
                        } else {
                            // Flag tasks that duplicate one you already have, so the review card can
                            // warn and let you confirm rather than silently piling on duplicates.
                            let existing = (try? modelContext.fetch(FetchDescriptor<TaskItem>()))?.map { $0.title } ?? []
                            var dups: [String: String] = [:]
                            for t in unique {
                                if let idx = TaskMatcher.bestMatchIndex(hint: t.title, titles: existing) {
                                    dups[t.title] = existing[idx]
                                }
                            }
                            duplicateOf = dups
                            withAnimation { state = .reviewing(unique) }
                        }
                    }
                }
            } catch {
                speak("Something went wrong. Please try again.")
                withAnimation { state = .ready }
            }
        }
    }

    private func executeCommand(_ command: ParsedDump.VoiceCommand) {
        NSLog("[voxdump:cmd] executing: %@", String(describing: command))
        switch command {
        case .completeAll:
            let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isCompleted })
            if let tasks = try? modelContext.fetch(descriptor) {
                tasks.forEach { $0.isCompleted = true; $0.microSteps.forEach { $0.isCompleted = true } }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()

        case .completeN(let n):
            var descriptor = FetchDescriptor<TaskItem>(
                predicate: #Predicate { !$0.isCompleted },
                sortBy: [SortDescriptor(\TaskItem.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = n
            if let tasks = try? modelContext.fetch(descriptor) {
                tasks.forEach { $0.isCompleted = true; $0.microSteps.forEach { $0.isCompleted = true } }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()

        case .deleteAll:
            // Irreversible whole-list wipe: confirm with an explicit tap before deleting anything.
            let count = (try? modelContext.fetch(FetchDescriptor<TaskItem>()))?.count ?? 0
            guard count > 0 else { speak("You don't have any tasks to delete."); dismiss(); return }
            pendingBulkDelete = PendingBulkDelete(kind: .all, count: count)
            beginBulkConfirmVoice()

        case .completeAndClear:
            // Completes everything then deletes it, so it empties the list: confirm first.
            let count = (try? modelContext.fetch(FetchDescriptor<TaskItem>()))?.count ?? 0
            guard count > 0 else { dismiss(); return }
            pendingBulkDelete = PendingBulkDelete(kind: .completeAndClear, count: count)
            beginBulkConfirmVoice()

        case .completeNamed(let hint):
            let descriptor = FetchDescriptor<TaskItem>(
                predicate: #Predicate { !$0.isCompleted },
                sortBy: [SortDescriptor(\TaskItem.createdAt, order: .reverse)]
            )
            if let tasks = try? modelContext.fetch(descriptor) {
                let match = TaskMatcher.bestMatchIndex(hint: hint, titles: tasks.map { $0.title }).map { tasks[$0] }
                #if DEBUG
                BDLog.command.notice("completeNamed hint=\(hint, privacy: .public) match=\(match?.title ?? "nil", privacy: .public) candidates=\(tasks.count, privacy: .public)")
                #else
                BDLog.command.notice("completeNamed hint=\(hint, privacy: .private) match=\(match?.title ?? "nil", privacy: .private) candidates=\(tasks.count, privacy: .public)")
                #endif
                if let task = match {
                    task.isCompleted = true
                    task.microSteps.forEach { $0.isCompleted = true }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    speak("I couldn't find a task matching \(hint). Tap the task in your list to mark it done.")
                }
            }
            dismiss()

        case .deleteNamed(let hint):
            let cleanHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
            // Never mass-delete: an unresolved named delete leaves everything untouched.
            guard !cleanHint.isEmpty else {
                BDLog.command.notice("deleteNamed empty hint -> no-op (never deletes all)")
                speak("I wasn't sure which task you meant, so I didn't delete anything.")
                dismiss()
                return
            }
            let descriptor = FetchDescriptor<TaskItem>(
                sortBy: [SortDescriptor(\TaskItem.createdAt, order: .reverse)]
            )
            if let tasks = try? modelContext.fetch(descriptor) {
                let match = TaskMatcher.bestMatchIndex(hint: cleanHint, titles: tasks.map { $0.title }).map { tasks[$0] }
                #if DEBUG
                BDLog.command.notice("deleteNamed hint=\(cleanHint, privacy: .public) match=\(match?.title ?? "nil", privacy: .public) candidates=\(tasks.count, privacy: .public)")
                #else
                BDLog.command.notice("deleteNamed hint=\(cleanHint, privacy: .private) match=\(match?.title ?? "nil", privacy: .private) candidates=\(tasks.count, privacy: .public)")
                #endif
                if let task = match {
                    modelContext.delete(task)
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                } else {
                    speak("I couldn't find a task matching \(cleanHint). Tap the task in your list to delete it.")
                }
            }
            dismiss()

        case .deleteCompleted:
            let count = (try? modelContext.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.isCompleted })))?.count ?? 0
            guard count > 0 else { speak("You don't have any completed tasks to clear."); dismiss(); return }
            pendingBulkDelete = PendingBulkDelete(kind: .completed, count: count)
            beginBulkConfirmVoice()

        case .reactivateNamed(let hint):
            let descriptor = FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.isCompleted },
                sortBy: [SortDescriptor(\TaskItem.createdAt, order: .reverse)]
            )
            if let tasks = try? modelContext.fetch(descriptor) {
                let match = TaskMatcher.bestMatchIndex(hint: hint, titles: tasks.map { $0.title }).map { tasks[$0] }
                #if DEBUG
                BDLog.command.notice("reactivateNamed hint=\(hint, privacy: .public) match=\(match?.title ?? "nil", privacy: .public) candidates=\(tasks.count, privacy: .public)")
                #else
                BDLog.command.notice("reactivateNamed hint=\(hint, privacy: .private) match=\(match?.title ?? "nil", privacy: .private) candidates=\(tasks.count, privacy: .public)")
                #endif
                if let task = match {
                    task.isCompleted = false
                    task.microSteps.forEach { $0.isCompleted = false }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    speak("I couldn't find a completed task matching \(hint).")
                }
            }
            dismiss()

        case .reactivateAll:
            let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.isCompleted })
            let tasks = (try? modelContext.fetch(descriptor)) ?? []
            BDLog.command.notice("reactivateAll reopened=\(tasks.count, privacy: .public)")
            if tasks.isEmpty {
                speak("You don't have any completed tasks to reopen.")
            } else {
                tasks.forEach { $0.isCompleted = false; $0.microSteps.forEach { $0.isCompleted = false } }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            dismiss()

        case .reactivateN(let n):
            var descriptor = FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.isCompleted },
                sortBy: [SortDescriptor(\TaskItem.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = n
            let tasks = (try? modelContext.fetch(descriptor)) ?? []
            BDLog.command.notice("reactivateN n=\(n, privacy: .public) reopened=\(tasks.count, privacy: .public)")
            if tasks.isEmpty {
                speak("You don't have any completed tasks to reopen.")
            } else {
                tasks.forEach { $0.isCompleted = false; $0.microSteps.forEach { $0.isCompleted = false } }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            dismiss()

        case .showTasks, .readTasks, .scheduleReminder:
            // Bubble up to ContentView which has access to all tasks and SpeakManager
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onCommand(command) }
        }
    }

    // Runs the actual bulk deletion, only after the user confirmed in the dialog.
    private func performBulkDelete(_ kind: BulkDeleteKind) {
        confirmVoiceActive = false
        speech.stopRecording()
        switch kind {
        case .all:
            if let tasks = try? modelContext.fetch(FetchDescriptor<TaskItem>()) {
                tasks.forEach { modelContext.delete($0) }
            }
        case .completeAndClear:
            if let tasks = try? modelContext.fetch(FetchDescriptor<TaskItem>()) {
                tasks.forEach { $0.isCompleted = true; $0.microSteps.forEach { $0.isCompleted = true } }
            }
            let doneDesc = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.isCompleted })
            if let tasks = try? modelContext.fetch(doneDesc) { tasks.forEach { modelContext.delete($0) } }
        case .completed:
            let doneDesc = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.isCompleted })
            if let tasks = try? modelContext.fetch(doneDesc) { tasks.forEach { modelContext.delete($0) } }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        pendingBulkDelete = nil
        dismiss()
    }

    // Speak the confirmation prompt; the mic is armed for yes/no only AFTER it finishes
    // (see .onChange(speaker.isSpeaking)), so the app never hears its own prompt. Device only.
    private func beginBulkConfirmVoice() {
        guard !textMode, let pending = pendingBulkDelete else { return }
        confirmVoiceActive = true
        speech.stopRecording()
        speaker.speak(pending.spokenPrompt)
    }

    private func armConfirmMic() {
        guard confirmVoiceActive, !textMode, pendingBulkDelete != nil else { return }
        // Small settle after TTS playback before switching the session back to record.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard confirmVoiceActive, pendingBulkDelete != nil else { return }
            speech.onSilenceDetected = { handleConfirmVoice(speech.transcript) }
            do {
                try speech.startRecording()
                BDLog.command.log("bulk-delete: listening for yes/no")
            } catch {
                BDLog.command.error("bulk-delete confirm mic failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleConfirmVoice(_ text: String) {
        guard confirmVoiceActive, let pending = pendingBulkDelete else { return }
        let verdict = BulkDeleteConfirmMatcher.match(text)
        #if DEBUG
        BDLog.command.log("bulk-delete heard '\(text, privacy: .public)' -> \(String(describing: verdict), privacy: .public)")
        #else
        BDLog.command.log("bulk-delete heard '\(text, privacy: .private)' -> \(String(describing: verdict), privacy: .public)")
        #endif
        switch verdict {
        case .confirm:
            performBulkDelete(pending.kind)              // stops the mic, deletes, dismisses
        case .cancel:
            confirmVoiceActive = false
            speech.stopRecording()
            pendingBulkDelete = nil
            dismiss()
        case .none:
            DispatchQueue.main.async { armConfirmMic() }  // unclear: keep listening, never auto-confirm
        }
    }

    private func save(_ task: ParsedTask) {
        let item = TaskItem(
            title: task.title,
            category: task.category,
            relativeTime: task.relativeTime,
            urgency: task.urgency,
            originalQuote: task.originalQuote
        )
        modelContext.insert(item)
        for (i, stepText) in task.microSteps.enumerated() {
            let step = MicroStep(text: stepText, order: i)
            modelContext.insert(step)
            item.microSteps.append(step)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Starting

private struct StartingView: View {
    var body: some View {
        VStack { Spacer(); ProgressView().tint(.white).scaleEffect(1.4); Spacer() }
    }
}

// MARK: - Ready

private struct ReadyView: View {
    let authStatus: SFSpeechRecognizerAuthorizationStatus
    let micGranted: Bool
    @Binding var textMode: Bool
    @Binding var manualInput: String
    let onStart: () -> Void
    let onProcessText: () -> Void
    let onCancel: () -> Void

    @State private var pulse: CGFloat = 1.0
    private var fullyAuthorized: Bool { authStatus == .authorized && micGranted }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .foregroundStyle(Color.bdMuted).padding()
            }
            Spacer()

            VStack(spacing: 8) {
                Text("Voxdump")
                    .font(.bdTitle()).foregroundStyle(.white)
                Text("Open, speak, done.")
                    .font(.bdBody()).foregroundStyle(Color.bdMuted)
            }

            Spacer().frame(height: 48)

            if textMode {
                VStack(spacing: 16) {
                    ZStack(alignment: .topLeading) {
                        if manualInput.isEmpty {
                            Text("Type your vox dump here…")
                                .font(.bdBody()).foregroundStyle(Color.bdMuted2).padding(14)
                        }
                        TextEditor(text: $manualInput)
                            .font(.bdBody()).foregroundStyle(.white)
                            .scrollContentBackground(.hidden)
                            .frame(height: 150).padding(8)
                    }
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.bdCard))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.bdBorder, lineWidth: 1))
                    .padding(.horizontal)

                    Button(action: onProcessText) {
                        Text("Parse Tasks →")
                            .font(.bdBody()).fontWeight(.semibold).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color.bdPrimary).cornerRadius(14)
                    }
                    .padding(.horizontal)
                    .disabled(manualInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                ZStack {
                    // Outer glow rings
                    Circle().fill(Color.bdPrimary.opacity(0.06))
                        .frame(width: 240, height: 240)
                        .scaleEffect(pulse)
                        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: pulse)
                    Circle().fill(Color.bdPrimary.opacity(0.10)).frame(width: 190, height: 190)

                    Button(action: onStart) {
                        Circle()
                            .fill(Color.bdPrimary)
                            .frame(width: 140, height: 140)
                            .overlay {
                                Image(systemName: fullyAuthorized ? "mic.fill" : "mic.slash.fill")
                                    .font(.system(size: 52, weight: .medium)).foregroundStyle(.white)
                            }
                            .shadow(color: Color.bdPrimary.opacity(0.55), radius: 28, x: 0, y: 8)
                    }
                }
                .onAppear { pulse = 1.1 }

                if !fullyAuthorized {
                    Button("Use text input instead") { textMode = true }
                        .font(.system(size: 13)).foregroundStyle(Color.bdMuted).padding(.top, 20)
                }
            }

            Spacer()
        }
    }
}

// MARK: - Recording

private struct RecordingView: View {
    @ObservedObject var speech: SpeechManager
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Text(speech.autoStopImminent ? "Almost done…" : "Listening…")
                .font(.bdHeadline()).foregroundStyle(.white)
                .animation(.easeInOut(duration: 0.2), value: speech.autoStopImminent)

            WaveformView(active: speech.isRecording && !speech.autoStopImminent)
                .frame(height: 56).padding(.horizontal, 32)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(speech.transcript.isEmpty ? "Start talking…" : speech.transcript)
                        .font(.bdBody())
                        .foregroundStyle(speech.transcript.isEmpty ? Color.bdMuted2 : Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .id("bottom")
                }
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.bdCard))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.bdBorder, lineWidth: 1))
                .padding(.horizontal)
                .onChange(of: speech.transcript) { _, _ in
                    withAnimation { proxy.scrollTo("bottom") }
                }
            }

            Spacer()

            Button(action: onStop) {
                ZStack {
                    Circle().fill(Color.bdRed.opacity(0.12)).frame(width: 96, height: 96)
                    if speech.autoStopImminent {
                        Circle()
                            .trim(from: 0, to: speech.autoStopImminent ? 0 : 1)
                            .stroke(Color.bdRed.opacity(0.6),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 96, height: 96)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.5), value: speech.autoStopImminent)
                    }
                    RoundedRectangle(cornerRadius: 8).fill(Color.bdRed).frame(width: 32, height: 32)
                }
            }

            Text(speech.autoStopImminent ? "Stopping…" : "Tap to stop")
                .font(.bdCaption()).foregroundStyle(Color.bdMuted)
                .animation(.easeInOut(duration: 0.2), value: speech.autoStopImminent)

            Spacer().frame(height: 40)
        }
    }
}

// MARK: - Waveform

private struct WaveformView: View {
    let active: Bool
    @State private var heights: [CGFloat] = Array(repeating: 8, count: 28)
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<heights.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.bdPrimary)
                    .frame(width: 4, height: heights[i])
                    .animation(.easeInOut(duration: 0.15), value: heights[i])
            }
        }
        .onAppear { if active { start() } }
        .onDisappear { stop() }
        .onChange(of: active) { _, v in v ? start() : stop() }
    }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { _ in
            for i in heights.indices { heights[i] = .random(in: 8...50) }
        }
    }
    private func stop() {
        timer?.invalidate(); timer = nil
        heights = Array(repeating: 8, count: 28)
    }
}

// MARK: - Processing

private struct ProcessingView: View {
    let mode: AIParsingManager.ParsingMode
    @State private var spin: Double = 0
    @State private var visible = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle().stroke(Color.bdPrimary.opacity(0.15), lineWidth: 3).frame(width: 76, height: 76)
                Circle().trim(from: 0, to: 0.72)
                    .stroke(Color.bdPrimary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 76, height: 76)
                    .rotationEffect(.degrees(spin))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            }
            .onAppear { spin = 360 }

            VStack(spacing: 8) {
                Text("Organizing your thoughts…")
                    .font(.bdHeadline()).foregroundStyle(.white)
                Text(mode == .fallback ? "Using smart pattern matching" : "Apple Intelligence on-device")
                    .font(.bdCaption()).foregroundStyle(Color.bdMuted)
            }
            .opacity(visible ? 1 : 0)
            .onAppear { withAnimation(.easeIn(duration: 0.3)) { visible = true } }

            Spacer()
        }
    }
}

// MARK: - Card review

struct CardReviewView: View {
    let tasks: [ParsedTask]
    var duplicateOf: [String: String] = [:]
    @ObservedObject var speech: SpeechManager
    var voiceEnabled: Bool = false
    let onKeep: (ParsedTask) -> Void
    let onFinish: () -> Void

    // Working set: the cards still under review. Accept/decline REMOVE the current
    // card (accept also saves via onKeep); when it empties, review is done. Kept
    // separate from a plain scroll index so swipe can browse freely without ever
    // re-accepting a card that was already actioned.
    @State private var working: [ParsedTask] = []
    @State private var index = 0
    @State private var didInit = false

    @State private var drag: CGSize = .zero
    @State private var rot: Double = 0
    @State private var showEditSheet = false
    @State private var editedTitle = ""
    @State private var editedSteps: [String] = []
    // Tracks whether we intend the review mic to be live, so a delayed (re)arm
    // never fires after the card advanced or the sheet was dismissed.
    @State private var voiceActive = false
    // Set while an action is being applied so a trailing transcript update can't
    // fire the same command twice before the card re-arms.
    @State private var actionInFlight = false
    // Let the audio session settle after the previous stopRecording() before we
    // reactivate it (starting the engine immediately after deactivation throws
    // intermittently and used to leave the mic silently dead).
    private let reArmDelay: TimeInterval = 0.3

    // Swipe browses only when there is more than one card to move between; a lone
    // card is accepted/declined via the buttons or voice, so swipe would be redundant.
    private var canBrowse: Bool { working.count > 1 }
    private var current: ParsedTask? { working.indices.contains(index) ? working[index] : nil }
    private var hasNext: Bool { index + 1 < working.count }
    private var duplicateWarning: String? { current.flatMap { duplicateOf[$0.title] } }

    var body: some View {
        Group {
            if let current {
                reviewBody(current)
            } else {
                // Transient empty frame between the last removal and onFinish().
                Color.bdBg
            }
        }
        .sheet(isPresented: $showEditSheet) {
            EditTaskSheet(
                title: $editedTitle,
                steps: $editedSteps,
                voiceEnabled: voiceEnabled,
                onSave: commitEdit
            )
            .presentationDetents([.large])
        }
        // Entering/leaving the edit sheet re-arms so the matcher switches between
        // review commands (accept/decline/edit) and edit commands (title/steps/save).
        .onChange(of: showEditSheet) { _, _ in armVoice() }
        // Match commands as the recognizer produces them (review), or on the finalized
        // phrase (edit); evaluate() branches on showEditSheet.
        .onChange(of: speech.transcript) { _, txt in evaluate(txt, live: true) }
        .onAppear {
            if !didInit { working = tasks; didInit = true }
            armVoice()
        }
        .onDisappear { if voiceEnabled { stopVoice() } }
    }

    @ViewBuilder
    private func reviewBody(_ current: ParsedTask) -> some View {
        VStack(spacing: 16) {
            // Progress segments (current position highlighted; this is a browse index now).
            HStack(spacing: 5) {
                ForEach(0..<working.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i == index ? Color.bdPrimary : Color.bdBorder)
                        .frame(height: 4)
                        .animation(.spring(response: 0.3), value: index)
                }
            }
            .padding(.horizontal, 24).padding(.top, 20)

            Text("\(index + 1) of \(working.count)")
                .font(.bdCaption()).foregroundStyle(Color.bdMuted)

            if let existing = duplicateWarning {
                Text("You already have \"\(existing)\". Keep to add it anyway, or skip.")
                    .font(.bdCaption())
                    .foregroundStyle(Color.bdRed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            }

            Spacer()

            ZStack {
                if hasNext {
                    TaskCard(task: working[index + 1])
                        .scaleEffect(0.92).offset(y: 18).opacity(0.5)
                }
                TaskCard(task: current)
                    .offset(drag)
                    .rotationEffect(.degrees(rot))
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                guard canBrowse else { return }
                                drag = v.translation
                                rot = Double(v.translation.width / 28)
                            }
                            .onEnded { v in
                                guard canBrowse else { return }
                                // Right = forward/next, matching TaskFocusView's swipe convention.
                                if v.translation.width > 80       { goToNext() }
                                else if v.translation.width < -80 { goToPrevious() }
                                else { snapBack() }
                            }
                    )
            }
            .padding(.horizontal, 20)

            Spacer()

            HStack(spacing: 32) {
                labeledButton(icon: "xmark", label: "Decline", color: Color.bdRed) { decline() }
                labeledButton(icon: "pencil", label: "Edit", color: Color.bdMuted) { beginEdit(current) }
                labeledButton(icon: "checkmark", label: "Accept", color: Color.bdGreen) { accept() }
            }
            .padding(.bottom, canBrowse ? 12 : (voiceEnabled ? 8 : 40))

            if canBrowse {
                Text("Swipe to browse all \(working.count)")
                    .font(.bdMicro()).foregroundStyle(Color.bdMuted2)
                    .padding(.bottom, voiceEnabled ? 4 : 24)
            }

            if voiceEnabled {
                HStack(spacing: 7) {
                    Image(systemName: speech.isRecording ? "waveform" : "mic.slash.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(speech.isRecording ? Color.bdGreen : Color.bdMuted2)
                        .symbolEffect(.variableColor.iterative, isActive: speech.isRecording)
                    Text(speech.isRecording
                         ? "Listening… say \"accept\", \"decline\", or \"edit\""
                         : "Say \"accept\", \"decline\", or \"edit\"")
                        .font(.bdMicro()).foregroundStyle(Color.bdMuted2)
                }
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: Review actions (accept/decline consume the current card; edit mutates in place)

    private func beginEdit(_ task: ParsedTask) {
        editedTitle = task.title
        editedSteps = task.microSteps
        showEditSheet = true
    }

    private func accept() {
        guard let task = current, !actionInFlight else { return }
        actionInFlight = true
        speech.stopRecording()
        onKeep(task)
        animateOutAndRemove(.right)
    }

    private func decline() {
        guard current != nil, !actionInFlight else { return }
        actionInFlight = true
        speech.stopRecording()
        animateOutAndRemove(.left)
    }

    private func goToNext() {
        guard index + 1 < working.count else { snapBack(); return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            drag = .zero; rot = 0; index += 1
        }
    }

    private func goToPrevious() {
        guard index > 0 else { snapBack(); return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            drag = .zero; rot = 0; index -= 1
        }
    }

    private func snapBack() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { drag = .zero; rot = 0 }
    }

    private enum Side { case left, right }

    private func animateOutAndRemove(_ side: Side) {
        let tx: CGFloat = side == .right ? 520 : -520
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            drag = CGSize(width: tx, height: 0); rot = side == .right ? 16 : -16
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { removeCurrent() }
    }

    private func removeCurrent() {
        drag = .zero; rot = 0
        guard working.indices.contains(index) else { return }
        working.remove(at: index)
        if working.isEmpty {
            stopVoice()
            onFinish()
            return
        }
        if index >= working.count { index = working.count - 1 }
        actionInFlight = false
        // index may not change (removed the last card and clamped, or a middle card so
        // the next slides into place), so re-arm explicitly rather than via onChange.
        armVoice()
    }

    // MARK: Hands-free voice (device only)

    // Keep a mic live and map spoken commands to the same actions as the buttons. Gated to
    // device (voiceEnabled). Context-aware: review commands on the card, edit commands
    // (title/steps/save/cancel) while the edit sheet is open.
    private func armVoice() {
        guard voiceEnabled else { return }
        voiceActive = true
        actionInFlight = false
        speech.stopRecording()
        scheduleArm(attempt: 0)
    }

    private func scheduleArm(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + reArmDelay) {
            // Bail if we left review during the settle window, else we would revive a dead mic.
            guard voiceActive, voiceEnabled else { return }
            speech.onSilenceDetected = { evaluate(speech.transcript, live: false) }
            do {
                try speech.startRecording()
                BDLog.speech.log("review: mic armed (card \(index), editing \(showEditSheet), attempt \(attempt))")
            } catch {
                BDLog.speech.error("review: mic arm failed (card \(index), attempt \(attempt)): \(error.localizedDescription, privacy: .public)")
                if attempt < 2 { scheduleArm(attempt: attempt + 1) }
            }
        }
    }

    private func stopVoice() {
        voiceActive = false
        speech.stopRecording()
    }

    // Evaluate a (possibly partial) transcript. Review commands fire live (instantly);
    // edit commands fire only on the finalized (silence) phrase so a multi-word
    // "change the title to ..." is not applied word by word.
    private func evaluate(_ text: String, live: Bool) {
        guard voiceActive, !actionInFlight else { return }

        if showEditSheet {
            if let cmd = EditCommandMatcher.match(text) {
                // setTitle/addStep carry multi-word content, so commit them only on the
                // finalized (silence) transcript to avoid truncating a partial. Short
                // commands (save/cancel/removeStep/clearSteps) fire LIVE so "save" is instant
                // (matching the pre-rework behavior that regressed to a ~2.5s silence wait).
                let needsFullPhrase: Bool = { switch cmd { case .setTitle, .addStep: return true; default: return false } }()
                if !(live && needsFullPhrase) {
                    logHeard(text, result: "\(cmd)")
                    applyEdit(cmd)
                    return
                }
            }
            if !live { logHeard(text, result: "no match"); armVoice() }
            return
        }

        guard let action = ReviewCommandMatcher.match(text, editing: false) else {
            if !live { logHeard(text, result: "no match"); armVoice() }
            return
        }
        logHeard(text, result: "\(action)")
        perform(action)
    }

    private func perform(_ action: ReviewCommand) {
        switch action {
        case .accept:  accept()
        case .decline: decline()
        case .edit:    if let c = current { beginEdit(c) }
        case .save:    commitEdit()          // unreachable from review mode; kept for exhaustiveness
        case .cancel:  showEditSheet = false
        case .done:    stopVoice(); onFinish()
        }
    }

    // Apply a spoken edit command to the working title/steps, then keep listening. Sets
    // actionInFlight and stops the recognizer first so a trailing partial cannot double-fire.
    private func applyEdit(_ cmd: EditCommand) {
        actionInFlight = true
        speech.stopRecording()
        switch cmd {
        case .setTitle(let s):   editedTitle = s; armVoice()
        case .addStep(let s):    editedSteps.append(s); armVoice()
        case .removeStep(let n): if editedSteps.indices.contains(n - 1) { editedSteps.remove(at: n - 1) }; armVoice()
        case .removeLastStep:    if !editedSteps.isEmpty { editedSteps.removeLast() }; armVoice()
        case .clearSteps:        editedSteps.removeAll(); armVoice()
        case .save:              commitEdit()          // onChange(showEditSheet) re-arms review
        case .cancel:            showEditSheet = false  // onChange(showEditSheet) re-arms review
        }
    }

    // Build the edited task and close the sheet. Shared by the Save button and voice.
    private func commitEdit() {
        let t = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, working.indices.contains(index) else { return }
        let cleanedSteps = editedSteps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let c = working[index]
        working[index] = ParsedTask(
            title: t,
            category: c.category,
            relativeTime: c.relativeTime,
            urgency: c.urgency,
            microSteps: cleanedSteps,
            originalQuote: c.originalQuote
        )
        showEditSheet = false
    }

    private func logHeard(_ text: String, result: String) {
        // User content: public on debug builds (device-log QA), redacted in release.
        #if DEBUG
        BDLog.command.log("review heard '\(text, privacy: .public)' editing=\(showEditSheet) -> \(result, privacy: .public)")
        #else
        BDLog.command.log("review heard '\(text, privacy: .private)' editing=\(showEditSheet) -> \(result, privacy: .public)")
        #endif
    }

    private func labeledButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            circleButton(icon: icon, color: color, action: action)
            Text(label).font(.bdCaption()).foregroundStyle(color)
        }
    }

    private func circleButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color.opacity(0.12)).frame(width: 64, height: 64)
                Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(color)
            }
        }
    }
}

// MARK: - Inline task editor (continuous voice, no tap required)

private struct EditTaskSheet: View {
    @Binding var title: String
    @Binding var steps: [String]
    var voiceEnabled: Bool = false
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Task")
                .font(.bdBody()).foregroundStyle(Color.bdMuted)
                .padding(.top, 24).padding(.horizontal, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TITLE").font(.bdMicro()).foregroundStyle(Color.bdMuted)
                        TextField("Task title", text: $title, axis: .vertical)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(16)
                            .background(Color.bdCard2)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .lineLimit(2...4)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("MICRO-STEPS").font(.bdMicro()).foregroundStyle(Color.bdMuted)
                        ForEach(steps.indices, id: \.self) { i in
                            HStack(spacing: 10) {
                                Text("\(i + 1)")
                                    .font(.bdMicro()).foregroundStyle(Color.bdMuted2)
                                    .frame(width: 14)
                                TextField("Step \(i + 1)", text: $steps[i], axis: .vertical)
                                    .font(.bdBody()).foregroundStyle(.white)
                                    .padding(12)
                                    .background(Color.bdCard2)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .lineLimit(1...3)
                                Button {
                                    steps.remove(at: i)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 20)).foregroundStyle(Color.bdRed)
                                }
                            }
                        }
                        Button {
                            steps.append("")
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill").font(.system(size: 16))
                                Text("Add step").font(.bdCaption())
                            }
                            .foregroundStyle(Color.bdPrimary)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 24)
            }

            Button(action: onSave) {
                Text("Save")
                    .font(.bdBody())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.bdPrimary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 20).padding(.bottom, voiceEnabled ? 4 : 12)
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if voiceEnabled {
                Text("Listening. Say \"change the title to…\", \"remove step 2\", \"add a step…\", or \"save\".")
                    .font(.bdMicro()).foregroundStyle(Color.bdMuted2)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
        }
        .background(Color.bdBg.ignoresSafeArea())
    }
}

// MARK: - Task card face

private struct TaskCard: View {
    let task: ParsedTask

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CategoryChip(category: task.category)
                Spacer()
                if let label = task.timeLabel {
                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 10))
                        Text(label).font(.bdMicro())
                    }
                    .foregroundStyle(Color.bdMuted)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.bdCard2).cornerRadius(6)
                }
            }
            .padding(.horizontal, 22).padding(.top, 22)

            Spacer().frame(height: 14)

            Text(task.title)
                .font(.bdHeadline()).foregroundStyle(.white)
                .lineLimit(3).padding(.horizontal, 22)

            if let quote = task.originalQuote {
                Spacer().frame(height: 10)
                Text("\"\(quote)\"")
                    .font(.system(size: 12, weight: .regular, design: .serif))
                    .foregroundStyle(Color.bdMuted)
                    .italic()
                    .lineLimit(2)
                    .padding(.horizontal, 22)
            }

            Spacer().frame(height: 20)

            Text("MICRO-STEPS")
                .font(.bdMicro()).foregroundStyle(Color.bdMuted)
                .padding(.horizontal, 22)

            Spacer().frame(height: 10)

            ForEach(Array(task.microSteps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(Color.bdPrimary.opacity(0.15)).frame(width: 24, height: 24)
                        Text("\(i + 1)").font(.bdMicro()).foregroundStyle(Color.bdPrimary)
                    }
                    Text(step)
                        .font(.system(size: 14)).foregroundStyle(Color(white: 0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 22).padding(.bottom, 9)
            }

            Spacer().frame(height: 22)
        }
        .frame(maxWidth: .infinity, minHeight: 380, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.bdCard))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.bdBorder, lineWidth: 1))
    }
}
