import SwiftUI
import SwiftData

struct AllTasksView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    @State private var showBrainDump = false

    // Hands-free (always-on) voice. Device only: the simulator forces textMode elsewhere
    // and has no usable mic, so we keep the list touch-only there.
    @StateObject private var speech = SpeechManager()
    @StateObject private var speaker = SpeakManager()
    @State private var handsFree = true
    @State private var voiceActive = false
    @State private var actionInFlight = false
    @State private var openTaskID: PersistentIdentifier?
    @State private var pendingDelete: TaskItem?
    @State private var confirmingDelete = false

    private var pending: [TaskItem]   { allTasks.filter { !$0.isCompleted } }
    private var completed: [TaskItem] { allTasks.filter { $0.isCompleted } }

    private var voiceSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }
    // Listen only when hands-free is on AND nothing else owns the mic or foreground
    // (a brain dump is capturing, or we pushed into a task detail).
    private var listeningActive: Bool {
        voiceSupported && handsFree && !showBrainDump && openTaskID == nil
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.bdBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack(alignment: .center) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.bdMuted)
                            .frame(width: 34, height: 34)
                            .background(Color.bdCard)
                            .clipShape(Circle())
                    }
                    Spacer()
                    if !pending.isEmpty {
                        Text("\(pending.count) task\(pending.count == 1 ? "" : "s") left")
                            .font(.bdCaption()).foregroundStyle(Color.bdMuted)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.bdCard).cornerRadius(10)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)

                Text("Tasks")
                    .font(.bdTitle()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 8)

                if voiceSupported {
                    handsFreePill
                        .padding(.horizontal, 24).padding(.bottom, 10)
                }

                if allTasks.isEmpty {
                    Spacer()
                    EmptyTasksState()
                    Spacer()
                } else {
                    List {
                        ForEach(pending) { task in
                            NavigationLink(value: AppRoute.taskFocus(task.persistentModelID)) {
                                TaskRowView(task: task)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    task.isCompleted = true
                                    task.microSteps.forEach { $0.isCompleted = true }
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                } label: { Label("Done", systemImage: "checkmark.circle.fill") }
                                .tint(Color.bdGreen)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { modelContext.delete(task) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }

                        if !completed.isEmpty {
                            Section {
                                ForEach(completed) { task in
                                    NavigationLink(value: AppRoute.taskFocus(task.persistentModelID)) {
                                        TaskRowView(task: task).opacity(0.55)
                                    }
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        Button {
                                            task.isCompleted = false
                                            task.microSteps.forEach { $0.isCompleted = false }
                                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        } label: {
                                            Label("Reopen", systemImage: "arrow.uturn.backward.circle.fill")
                                        }
                                        .tint(.orange)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) { modelContext.delete(task) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                HStack {
                                    Text("COMPLETED")
                                        .font(.bdMicro()).foregroundStyle(Color.bdMuted2)
                                    Spacer()
                                    Button {
                                        completed.forEach { modelContext.delete($0) }
                                    } label: {
                                        Text("Clear all").font(.bdMicro()).foregroundStyle(Color.bdMuted)
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.bdBg)
                }
            }

            // FAB (tap still works; on device the always-on listener also opens this by voice)
            Button { showBrainDump = true } label: {
                ZStack {
                    Circle()
                        .fill(Color.bdPrimary)
                        .frame(width: 60, height: 60)
                        .shadow(color: Color.bdPrimary.opacity(0.45), radius: 16, x: 0, y: 6)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.trailing, 24).padding(.bottom, 44)
        }
        .navigationBarHidden(true)
        .navigationDestination(item: $openTaskID) { id in
            TaskFocusView(taskID: id)
        }
        .fullScreenCover(isPresented: $showBrainDump) {
            BrainDumpSheet(onComplete: { showBrainDump = false })
        }
        // Voice lifecycle: arm/stop as the foreground ownership changes. Authorize on this
        // instance first so the listener can actually record (SpeechManager seeds micGranted
        // from the system, and requesting also covers a cold first launch via the menu).
        .onAppear {
            Task { @MainActor in
                if voiceSupported { await speech.requestAuthorization() }
                syncVoice()
            }
        }
        .onDisappear { stopVoice() }
        .onChange(of: handsFree) { _, _ in syncVoice() }
        .onChange(of: showBrainDump) { _, _ in syncVoice() }
        .onChange(of: openTaskID) { _, _ in syncVoice() }
        // Arm the mic only AFTER our own speech finishes, so it never hears itself.
        .onChange(of: speaker.isSpeaking) { _, speaking in if !speaking { syncVoice() } }
        .onChange(of: speech.transcript) { _, txt in evaluate(txt, live: true) }
    }

    // MARK: - Hands-free indicator / mute toggle

    private var handsFreePill: some View {
        Button { handsFree.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: pillIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(handsFree ? Color.bdGreen : Color.bdMuted2)
                    .symbolEffect(.variableColor.iterative, isActive: listeningActive && speech.isRecording)
                Text(pillText)
                    .font(.bdMicro()).foregroundStyle(handsFree ? Color.bdMuted : Color.bdMuted2)
                Spacer()
                Text(handsFree ? "Mute" : "Unmute")
                    .font(.bdMicro()).foregroundStyle(Color.bdPrimary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.bdCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var pillIcon: String {
        if !handsFree { return "mic.slash.fill" }
        return (listeningActive && speech.isRecording) ? "waveform" : "mic.fill"
    }

    private var pillText: String {
        guard handsFree else { return "Hands-free off" }
        if confirmingDelete { return "Say \"yes\" to delete, or \"no\"" }
        return "Listening — try \"open\", \"complete\", or \"new task\""
    }

    // MARK: - Voice engine (mirrors CardReviewView's arm/re-arm pattern)

    private func syncVoice() {
        if listeningActive { armVoice() } else { stopVoice() }
    }

    private func armVoice() {
        guard listeningActive else { return }
        voiceActive = true
        actionInFlight = false
        speech.stopRecording()
        scheduleArm(attempt: 0)
    }

    private func scheduleArm(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard voiceActive, listeningActive, !speaker.isSpeaking else { return }
            speech.onSilenceDetected = { evaluate(speech.transcript, live: false) }
            do {
                try speech.startRecording()
                BDLog.speech.log("tasks: mic armed (attempt \(attempt))")
            } catch {
                BDLog.speech.error("tasks: mic arm failed (\(attempt)): \(error.localizedDescription, privacy: .public)")
                if attempt < 2 { scheduleArm(attempt: attempt + 1) }
            }
        }
    }

    private func stopVoice() {
        voiceActive = false
        speech.stopRecording()
    }

    private func evaluate(_ text: String, live: Bool) {
        guard voiceActive, !actionInFlight else { return }

        // While confirming a delete, only a clear spoken yes/no is honored.
        if confirmingDelete {
            guard let verdict = BulkDeleteConfirmMatcher.match(text) else {
                if !live { armVoice() }
                return
            }
            actionInFlight = true
            speech.stopRecording()
            if verdict == .confirm, let t = pendingDelete {
                modelContext.delete(t)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            pendingDelete = nil
            confirmingDelete = false
            armVoice()
            return
        }

        guard let cmd = NavCommandMatcher.match(text) else {
            if !live { armVoice() }
            return
        }
        logHeard(text, cmd: cmd)
        perform(cmd)
    }

    private func perform(_ cmd: NavCommand) {
        actionInFlight = true
        speech.stopRecording()
        switch cmd {
        case .mute:
            handsFree = false
            stopVoice()

        case .goBack:
            stopVoice()
            dismiss()

        case .newDump:
            showBrainDump = true          // syncVoice stops us; BrainDumpSheet owns the mic

        case .readTasks:
            speaker.readTasks(allTasks, filter: .pending)   // isSpeaking->false re-arms

        case .open(let hint):
            if let t = bestMatch(hint) {
                openTaskID = t.persistentModelID            // navigationDestination(item:) pushes
            } else {
                notFound(hint)
            }

        case .complete(let hint):
            if let t = bestMatch(hint) {
                t.isCompleted = true
                t.microSteps.forEach { $0.isCompleted = true }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                armVoice()
            } else {
                notFound(hint)
            }

        case .delete(let hint):
            if let t = bestMatch(hint) {
                pendingDelete = t
                confirmingDelete = true
                speaker.speak("Delete \(t.title)? Say yes to confirm, or no.")   // isSpeaking->false re-arms into confirm
            } else {
                notFound(hint)
            }
        }
    }

    private func notFound(_ hint: String) {
        speaker.speak("I couldn't find a task called \(hint).")   // isSpeaking->false re-arms
    }

    private func bestMatch(_ hint: String) -> TaskItem? {
        let titles = allTasks.map { $0.title }
        guard let idx = TaskMatcher.bestMatchIndex(hint: hint, titles: titles) else { return nil }
        return allTasks[idx]
    }

    private func logHeard(_ text: String, cmd: NavCommand?) {
        let verb = cmd.map { "\($0)" } ?? "no match"
        #if DEBUG
        BDLog.command.log("tasks heard '\(text, privacy: .public)' -> \(verb, privacy: .public)")
        #else
        BDLog.command.log("tasks heard '\(text, privacy: .private)' -> \(verb, privacy: .public)")
        #endif
    }
}

private struct EmptyTasksState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 54))
                .foregroundStyle(Color.bdPrimary.opacity(0.5))
            Text("Head empty, ready to capture")
                .font(.bdHeadline()).foregroundStyle(.white)
            Text("Tap the mic button to add tasks")
                .font(.bdBody()).foregroundStyle(Color.bdMuted)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}
