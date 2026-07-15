import SwiftUI
import SwiftData

struct AllTasksView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    @State private var showBrainDump = false

    // Hands-free (always-on) voice. Device only: the simulator forces textMode elsewhere
    // and has no usable mic, so we keep the list touch-only there.
    // Shared singleton: the Brain Dump sheet uses the same instance so the two never
    // fight over the mic / audio session during the list <-> sheet hand-off.
    @ObservedObject private var speech = SpeechManager.shared
    @StateObject private var speaker = SpeakManager()
    @State private var handsFree = true
    @State private var voiceActive = false
    @State private var actionInFlight = false
    @State private var openTaskID: PersistentIdentifier?
    // A pending destructive confirmation can cover one task or many (bulk "clear all").
    @State private var pendingDeletes: [TaskItem] = []
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

        }
        .navigationBarHidden(true)
        // Consistent bottom listening bar (replaces the old top pill + floating mic FAB): shows
        // the live transcript, a conveniently-placed mute, a command tooltip, and the + to capture.
        .safeAreaInset(edge: .bottom) {
            ListeningBar(
                speech: speech,
                voiceEnabled: voiceSupported,
                isListening: listeningActive,
                hint: confirmingDelete
                    ? "say \u{201C}yes\u{201D} to delete, or \u{201C}no\u{201D}"
                    : "\u{201C}complete the first\u{201D}, \u{201C}new task\u{201D}, \u{201C}clear all\u{201D}",
                handsFree: $handsFree,
                onNewDump: { showBrainDump = true }
            )
        }
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
        // Commands run only on the finalized utterance (speech.onSilenceDetected -> evaluate),
        // never on live partials — see the note in evaluate(). The ListeningBar shows the live
        // transcript by observing speech directly, so we no longer route partials here.
        #if DEBUG
        // QA seam: drive the real command path with an injected transcript (braindump://inject).
        .onReceive(NotificationCenter.default.publisher(for: .voxDebugInject)) { note in
            if let text = note.object as? String { evaluate(text, live: false, injected: true) }
        }
        #endif
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

    private func evaluate(_ text: String, live: Bool, injected: Bool = false) {
        // injected == a QA transcript from the braindump://inject debug URL: run the routing even
        // when the always-on listener is not armed (e.g. on the simulator, which has no mic).
        if injected { actionInFlight = false }
        guard injected || voiceActive, !actionInFlight else { return }
        // Act ONLY on the finalized utterance (after a short silence), never a live partial.
        // Partials like "Mark go" (mid "mark go to the gym…") were completing the first "go" task
        // before the sentence finished — the "too fast" reaction. Live partials now only feed the
        // on-screen transcript (the ListeningBar observes speech.transcript directly). Injected QA
        // transcripts are already final.
        if live && !injected { return }

        // While confirming a delete, only a clear spoken yes/no is honored.
        if confirmingDelete {
            guard let verdict = BulkDeleteConfirmMatcher.match(text) else {
                if !live { armVoice() }
                return
            }
            actionInFlight = true
            speech.stopRecording()
            if verdict == .confirm, !pendingDeletes.isEmpty {
                pendingDeletes.forEach { modelContext.delete($0) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            pendingDeletes = []
            confirmingDelete = false
            armVoice()
            return
        }

        guard let cmd = NavCommandMatcher.match(text) else {
            // Log on the finalized transcript so device logs show whether the mic is
            // actually producing speech here (diagnostic for the "listening does nothing" report).
            if !live { logHeard(text, cmd: nil); armVoice() }
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

        case .open:
            if let t = resolvedTasks(cmd).first {
                openTaskID = t.persistentModelID            // navigationDestination(item:) pushes
            } else {
                notFound()
            }

        case .complete:
            let targets = resolvedTasks(cmd)
            guard !targets.isEmpty else { notFound(); return }
            targets.forEach { t in
                t.isCompleted = true
                t.microSteps.forEach { $0.isCompleted = true }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // Speaking re-arms via speaker.isSpeaking->false; a single completion re-arms directly.
            if targets.count > 1 { speaker.speak("Completed \(targets.count) tasks.") } else { armVoice() }

        case .reopen:
            let targets = resolvedTasks(cmd)
            guard !targets.isEmpty else { notFound(); return }
            targets.forEach { t in
                t.isCompleted = false
                t.microSteps.forEach { $0.isCompleted = false }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if targets.count > 1 { speaker.speak("Reopened \(targets.count) tasks.") } else { armVoice() }

        case .delete:
            let targets = resolvedTasks(cmd)
            guard !targets.isEmpty else { notFound(); return }
            pendingDeletes = targets
            confirmingDelete = true
            let prompt = targets.count == 1
                ? "Delete \(targets[0].title)? Say yes to confirm, or no."
                : "Delete \(targets.count) tasks? Say yes to confirm, or no."
            speaker.speak(prompt)   // isSpeaking->false re-arms into the confirm listener
        }
    }

    /// Resolve a command's selector to concrete tasks via the pure NavCommandResolver, using
    /// allTasks in display order (most-recent first, matching the @Query sort). Complete/open
    /// target pending tasks; delete targets pending (or the whole list for "clear all"); reopen
    /// targets completed tasks — the resolver enforces this.
    private func resolvedTasks(_ cmd: NavCommand) -> [TaskItem] {
        let snapshot = allTasks.map {
            TaskSnapshot(title: $0.title, isCompleted: $0.isCompleted, createdAt: $0.createdAt)
        }
        return NavCommandResolver.resolve(cmd, in: snapshot, now: Date()).map { allTasks[$0] }
    }

    private func notFound() {
        speaker.speak("I couldn't find that task.")   // isSpeaking->false re-arms
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
