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
    private let synth = AVSpeechSynthesizer()

    @State private var state: DumpState = {
        #if targetEnvironment(simulator)
        return .ready
        #else
        return .starting
        #endif
    }()
    @State private var cardIndex = 0
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

    private enum DumpState {
        case starting, ready, recording, processing, reviewing([ParsedTask])
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
                    currentIndex: $cardIndex,
                    duplicateOf: duplicateOf,
                    onKeep: { save($0, tasks: tasks) },
                    onDiscard: { advance(tasks: tasks) },
                    onDone: { onComplete() }
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
                        cardIndex = 0
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
            let descriptor = FetchDescriptor<TaskItem>()
            if let tasks = try? modelContext.fetch(descriptor) { tasks.forEach { modelContext.delete($0) } }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            dismiss()

        case .completeAndClear:
            let allDesc = FetchDescriptor<TaskItem>()
            if let tasks = try? modelContext.fetch(allDesc) {
                tasks.forEach { $0.isCompleted = true; $0.microSteps.forEach { $0.isCompleted = true } }
            }
            let doneDesc = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.isCompleted })
            if let tasks = try? modelContext.fetch(doneDesc) { tasks.forEach { modelContext.delete($0) } }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()

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
            let descriptor = FetchDescriptor<TaskItem>(
                sortBy: [SortDescriptor(\TaskItem.createdAt, order: .reverse)]
            )
            if let tasks = try? modelContext.fetch(descriptor) {
                let match = TaskMatcher.bestMatchIndex(hint: hint, titles: tasks.map { $0.title }).map { tasks[$0] }
                #if DEBUG
                BDLog.command.notice("deleteNamed hint=\(hint, privacy: .public) match=\(match?.title ?? "nil", privacy: .public) candidates=\(tasks.count, privacy: .public)")
                #else
                BDLog.command.notice("deleteNamed hint=\(hint, privacy: .private) match=\(match?.title ?? "nil", privacy: .private) candidates=\(tasks.count, privacy: .public)")
                #endif
                if let task = match {
                    modelContext.delete(task)
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                } else {
                    speak("I couldn't find a task matching \(hint). Tap the task in your list to delete it.")
                }
            }
            dismiss()

        case .deleteCompleted:
            let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.isCompleted })
            if let tasks = try? modelContext.fetch(descriptor) { tasks.forEach { modelContext.delete($0) } }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()

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

    private func save(_ task: ParsedTask, tasks: [ParsedTask]) {
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
        advance(tasks: tasks)
    }

    private func advance(tasks: [ParsedTask]) {
        let next = cardIndex + 1
        if next >= tasks.count {
            onComplete()
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { cardIndex = next }
        }
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
    @Binding var currentIndex: Int
    var duplicateOf: [String: String] = [:]
    let onKeep: (ParsedTask) -> Void
    let onDiscard: () -> Void
    let onDone: () -> Void

    @State private var drag: CGSize = .zero
    @State private var rot: Double = 0
    @State private var showEditSheet = false
    @State private var editedTitle = ""
    @State private var editedCurrentTask: ParsedTask? = nil

    private var current: ParsedTask { editedCurrentTask ?? tasks[currentIndex] }
    private var hasNext: Bool { currentIndex + 1 < tasks.count }
    private var duplicateWarning: String? { duplicateOf[current.title] }

    var body: some View {
        VStack(spacing: 16) {
            // Progress segments
            HStack(spacing: 5) {
                ForEach(0..<tasks.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i <= currentIndex ? Color.bdPrimary : Color.bdBorder)
                        .frame(height: 4)
                        .animation(.spring(response: 0.3), value: currentIndex)
                }
            }
            .padding(.horizontal, 24).padding(.top, 20)

            Text("\(currentIndex + 1) of \(tasks.count)")
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
                    TaskCard(task: tasks[currentIndex + 1])
                        .scaleEffect(0.92).offset(y: 18).opacity(0.5)
                }
                TaskCard(task: current)
                    .offset(drag)
                    .rotationEffect(.degrees(rot))
                    .overlay(swipeOverlay)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                drag = v.translation
                                rot = Double(v.translation.width / 22)
                            }
                            .onEnded { v in
                                if v.translation.width > 100       { animateOut(.right) }
                                else if v.translation.width < -100 { animateOut(.left) }
                                else {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                        drag = .zero; rot = 0
                                    }
                                }
                            }
                    )
            }
            .padding(.horizontal, 20)

            Spacer()

            HStack(spacing: 32) {
                circleButton(icon: "xmark", color: Color.bdRed)    { animateOut(.left) }
                circleButton(icon: "pencil", color: Color.bdMuted)  {
                    editedTitle = current.title
                    showEditSheet = true
                }
                circleButton(icon: "checkmark", color: Color.bdGreen) { animateOut(.right) }
            }
            .padding(.bottom, 48)
        }
        .sheet(isPresented: $showEditSheet) {
            EditTaskSheet(title: $editedTitle) { newTitle in
                editedCurrentTask = ParsedTask(
                    title: newTitle,
                    category: current.category,
                    relativeTime: current.relativeTime,
                    urgency: current.urgency,
                    microSteps: current.microSteps,
                    originalQuote: current.originalQuote
                )
                showEditSheet = false
            }
            .presentationDetents([.medium])
        }
        .onChange(of: currentIndex) { _, _ in
            editedCurrentTask = nil  // reset edits when card advances
        }
    }

    @ViewBuilder
    private var swipeOverlay: some View {
        if drag.width > 30 {
            RoundedRectangle(cornerRadius: 24).strokeBorder(Color.bdGreen, lineWidth: 2.5)
                .overlay(alignment: .topLeading) {
                    Text("KEEP")
                        .font(.system(size: 24, weight: .black)).foregroundStyle(Color.bdGreen)
                        .rotationEffect(.degrees(-14)).padding(24)
                        .opacity(min(1, drag.width / 80))
                }
        } else if drag.width < -30 {
            RoundedRectangle(cornerRadius: 24).strokeBorder(Color.bdRed, lineWidth: 2.5)
                .overlay(alignment: .topTrailing) {
                    Text("SKIP")
                        .font(.system(size: 24, weight: .black)).foregroundStyle(Color.bdRed)
                        .rotationEffect(.degrees(14)).padding(24)
                        .opacity(min(1, abs(drag.width) / 80))
                }
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

    private enum Side { case left, right }

    private func animateOut(_ side: Side) {
        let tx: CGFloat = side == .right ? 520 : -520
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            drag = CGSize(width: tx, height: 0); rot = side == .right ? 16 : -16
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            drag = .zero; rot = 0
            if side == .right { onKeep(current) } else { onDiscard() }
        }
    }
}

// MARK: - Inline task title editor

private struct EditTaskSheet: View {
    @Binding var title: String
    let onSave: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit Task")
                .font(.bdBody()).foregroundStyle(Color.bdMuted)
                .padding(.top, 24).padding(.horizontal, 24)

            TextField("Task title", text: $title, axis: .vertical)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .padding(16)
                .background(Color.bdCard2)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)
                .focused($focused)
                .lineLimit(3...6)

            Button {
                onSave(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : title)
            } label: {
                Text("Save")
                    .font(.bdBody())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.bdPrimary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 20)
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()
        }
        .background(Color.bdBg.ignoresSafeArea())
        .onAppear { focused = true }
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
