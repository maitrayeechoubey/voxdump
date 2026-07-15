import SwiftUI
import SwiftData
import OSLog

enum AppRoute: Hashable {
    case allTasks
    case settings
    case taskFocus(PersistentIdentifier)
}

struct ContentView: View {
    @State private var navPath: [AppRoute] = []
    @State private var showBrainDump = false
    @State private var showDrawer = false
    @State private var showReentry = false
    @State private var sessionAutoStarted = false
    // Filter to apply when the tasks list opens (set by Home voice nav "show pending").
    @State private var tasksFilter: TaskFilter = .all
    // A task spoken on Home, handed to the capture sheet to parse (nil = normal record flow).
    @State private var homeDumpText: String? = nil
    @StateObject private var speakManager = SpeakManager()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<TaskItem> { !$0.isCompleted }) private var incompleteTasks: [TaskItem]
    @Query private var allTasks: [TaskItem]
    // @AppStorage observes UserDefaults KVO — fires immediately when intent writes the flag
    // in-process (the most reliable trigger when the app is already running).
    // UUID tokens replace bool flags: a new UUID is always a new value, so KVO fires
    // even if the intent is triggered twice in quick succession.
    @AppStorage("braindumpOpenToken") private var braindumpOpenToken: String = ""
    @AppStorage("braindumpShowTasksToken") private var braindumpShowTasksToken: String = ""

    var body: some View {
        NavigationStack(path: $navPath) {
            HomeView(
                onMicTap: { showBrainDump = true },
                onMenuTap: { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showDrawer = true } },
                onFirstAppear: {
                    guard !sessionAutoStarted else { return }
                    sessionAutoStarted = true
                    // Auto-open recording 1.5s after home screen appears,
                    // unless another sheet (reentry, pending dump) is already showing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        guard !showBrainDump && !showReentry else { return }
                        showBrainDump = true
                    }
                },
                onShowTasks: { filter in
                    tasksFilter = filter
                    sessionAutoStarted = true
                    navPath = [.allTasks]
                },
                onOpenTask: { id in
                    tasksFilter = .all
                    sessionAutoStarted = true
                    navPath = [.allTasks, .taskFocus(id)]
                },
                onCaptureText: { text in
                    // Home heard a spoken task (not a nav command) — hand it to capture to parse.
                    homeDumpText = text
                    sessionAutoStarted = true
                    showBrainDump = true
                },
                canListen: navPath.isEmpty && !showBrainDump && !showReentry && !showDrawer
            )
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .allTasks:                AllTasksView(initialFilter: tasksFilter)
                case .settings:               SettingsView()
                case .taskFocus(let id):       TaskFocusView(taskID: id)
                }
            }
        }
        .fullScreenCover(isPresented: $showBrainDump, onDismiss: { homeDumpText = nil }) {
            BrainDumpSheet(
                onComplete: {
                    showBrainDump = false
                    navPath = [.allTasks]
                },
                onCommand: { command in
                    handleVoiceCommand(command)
                },
                initialTranscript: homeDumpText
            )
        }
        .fullScreenCover(isPresented: $showReentry) {
            ReentryView(
                onContinue: { task in
                    showReentry = false
                    navPath = [.allTasks, .taskFocus(task.persistentModelID)]
                },
                onDismiss: { showReentry = false }
            )
        }
        .overlay {
            if showDrawer {
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { closeDrawer() }

                    DrawerView(
                        onAllTasks: {
                            closeDrawer()
                            navPath = [.allTasks]
                        },
                        onSettings: {
                            closeDrawer()
                            navPath = [.settings]
                        },
                        onClose: closeDrawer
                    )
                    .transition(.move(edge: .leading))
                }
            }
        }
        // Mechanism 1: UUID token KVO — primary trigger when intent runs in-process.
        // UUID changes on every intent call, so KVO fires even for back-to-back invocations.
        .onChange(of: braindumpOpenToken) { _, newValue in
            guard !newValue.isEmpty else { return }
            print("[braindump:nav] braindumpOpenToken changed (\(newValue.prefix(8))…), opening mic")
            openBrainDump()
        }
        .onChange(of: braindumpShowTasksToken) { _, newValue in
            guard !newValue.isEmpty else { return }
            print("[braindump:nav] braindumpShowTasksToken changed, navigating to tasks")
            sessionAutoStarted = true
            navPath = [.allTasks]
        }
        // Mechanism 2: Darwin / URL-scheme NC posted by FocusFlowApp.onOpenURL or the Darwin callback.
        .onReceive(NotificationCenter.default.publisher(for: .braindumpOpen)) { _ in
            print("[braindump:nav] received .braindumpOpen NC")
            openBrainDump()
        }
        .onReceive(NotificationCenter.default.publisher(for: .braindumpShowTasks)) { _ in
            print("[braindump:nav] received .braindumpShowTasks NC")
            sessionAutoStarted = true
            navPath = [.allTasks]
        }
        // Mechanism 3: didBecomeActive — last-resort check when the token was written before
        // the view was ready to observe it (e.g., app was mid-transition when intent fired).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            let token = UserDefaults.standard.string(forKey: "braindumpOpenToken") ?? ""
            if !token.isEmpty && token != braindumpOpenToken {
                print("[braindump:nav] didBecomeActive: stale open token found, opening mic")
                openBrainDump()
            }
            let showToken = UserDefaults.standard.string(forKey: "braindumpShowTasksToken") ?? ""
            if !showToken.isEmpty && showToken != braindumpShowTasksToken {
                print("[braindump:nav] didBecomeActive: stale show-tasks token found")
                sessionAutoStarted = true
                navPath = [.allTasks]
            }
            checkReentry()
        }
    }

    private func openBrainDump() {
        sessionAutoStarted = true
        if showBrainDump {
            // Sheet is already "shown" (stale state or concurrently triggered).
            // Toggle off → on so SwiftUI presents a fresh instance.
            showBrainDump = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showBrainDump = true }
        } else {
            showBrainDump = true
        }
    }

    private func closeDrawer() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showDrawer = false }
    }

    private func handleVoiceCommand(_ command: ParsedDump.VoiceCommand) {
        print("[braindump:command] handleVoiceCommand: \(command)")
        switch command {
        case .showTasks:
            showBrainDump = false
            navPath = [.allTasks]

        case .readTasks(let filter):
            speakManager.readTasks(allTasks, filter: filter)

        case .scheduleReminder(let taskHint, let rawTime):
            print("[braindump:reminder] scheduleReminder — hint: \"\(taskHint ?? "nil")\", rawTime: \"\(rawTime)\"")
            Task {
                let granted = await NotificationManager.shared.requestAuthorization()
                print("[braindump:reminder] auth granted: \(granted)")
                if let date = NotificationManager.shared.parseTime(from: rawTime) {
                    print("[braindump:reminder] parsed date: \(date)")
                    let body = taskHint ?? "Time to check your tasks!"
                    NotificationManager.shared.schedule(title: "Voxdump Reminder", body: body, at: date)
                    speakManager.speak("Got it. I'll remind you \(rawTime).")
                } else if let hint = taskHint, !hint.isEmpty {
                    // AI said "schedule_reminder" but gave no parseable time — treat as a task.
                    print("[braindump:reminder] no parseable time, creating task from hint: \"\(hint)\"")
                    let item = TaskItem(title: hint, category: "PERSONAL", urgency: "medium")
                    modelContext.insert(item)
                    speakManager.speak("I didn't catch a time, so I saved \"\(hint)\" as a task instead.")
                } else {
                    speakManager.speak("Sorry, I couldn't understand that time. Try saying something like: in 30 minutes, or at 3pm.")
                }
            }

        default:
            break
        }
    }

    private func checkReentry() {
        guard !incompleteTasks.isEmpty else { return }
        guard let last = UserDefaults.standard.object(forKey: "lastActiveDate") as? Date else { return }
        let elapsed = Date().timeIntervalSince(last)
        if elapsed > 3600 {
            showReentry = true
        }
    }
}

// MARK: - Home screen

private struct HomeView: View {
    let onMicTap: () -> Void
    let onMenuTap: () -> Void
    var onFirstAppear: () -> Void = {}
    var onShowTasks: (TaskFilter) -> Void = { _ in }
    var onOpenTask: (PersistentIdentifier) -> Void = { _ in }
    /// A phrase heard on Home that isn't a navigation command — hand to capture to parse.
    var onCaptureText: (String) -> Void = { _ in }
    /// ContentView tells us when Home actually owns the foreground/mic (no sheet, drawer, or push).
    var canListen: Bool = false

    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    @ObservedObject private var speech = SpeechManager.shared
    @StateObject private var speaker = SpeakManager()
    @State private var handsFree = true
    @State private var voiceActive = false
    @State private var actionInFlight = false
    @State private var pulse: CGFloat = 1.0
    @State private var glowOpacity: CGFloat = 0.4

    private var recent: [TaskItem] { Array(allTasks.prefix(3)) }
    private var voiceSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }
    private var listeningActive: Bool { voiceSupported && handsFree && canListen }

    var body: some View {
        ZStack {
            Color.bdBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                HStack {
                    Button(action: onMenuTap) {
                        VStack(spacing: 5) {
                            ForEach(0..<3, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(.white)
                                    .frame(width: 22, height: 2)
                            }
                        }
                        .frame(width: 40, height: 40)
                    }
                    Spacer()
                    Text("voxdump")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.bdMuted)
                    Spacer()
                    Color.clear.frame(width: 40, height: 40)
                }
                .padding(.horizontal, 20).padding(.top, 16)

                Spacer()

                VStack(spacing: 12) {
                    Text("Voxdump")
                        .font(.bdTitle()).foregroundStyle(.white)
                    Text("Open, speak, done.")
                        .font(.bdBody()).foregroundStyle(Color.bdMuted)
                }

                Spacer().frame(height: 36)

                // Tap-to-capture hero (kept). Voice always-on runs in the background; this stays as
                // the primary tap affordance.
                ZStack {
                    Circle()
                        .fill(Color.bdPrimary.opacity(0.06))
                        .frame(width: 220, height: 220)
                        .scaleEffect(pulse)
                        .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: pulse)
                    Circle()
                        .fill(Color.bdPrimary.opacity(0.10))
                        .frame(width: 168, height: 168)
                    Button(action: onMicTap) {
                        ZStack {
                            Circle()
                                .fill(Color.bdPrimary)
                                .frame(width: 130, height: 130)
                                .shadow(color: Color.bdPrimary.opacity(glowOpacity), radius: 32, x: 0, y: 0)
                                .shadow(color: Color.bdPrimary.opacity(0.25), radius: 16, x: 0, y: 8)
                            Image(systemName: "mic.fill")
                                .font(.system(size: 48, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onAppear {
                    pulse = 1.09
                    glowOpacity = 0.65
                    onFirstAppear()
                }

                if !recent.isEmpty { recentSection }

                Spacer()
            }
        }
        .navigationBarHidden(true)
        // Consistent bottom listening bar (same as the Tasks list). Always-on on device; the record
        // mic is always tappable, even when muted.
        .safeAreaInset(edge: .bottom) {
            ListeningBar(
                speech: speech,
                voiceEnabled: voiceSupported,
                isListening: listeningActive,
                hint: "\u{201C}show my tasks\u{201D}, \u{201C}show pending\u{201D}, \u{201C}new task\u{201D}",
                handsFree: $handsFree,
                onNewDump: onMicTap
            )
        }
        .onAppear { syncVoice() }
        .onDisappear { stopVoice() }
        .onChange(of: canListen) { _, _ in syncVoice() }
        .onChange(of: handsFree) { _, _ in syncVoice() }
        .onChange(of: speaker.isSpeaking) { _, speaking in if !speaking { syncVoice() } }
        #if DEBUG
        // QA seam: only handle injected transcripts while Home is the foreground surface, so it
        // never double-fires with the Tasks list's observer.
        .onReceive(NotificationCenter.default.publisher(for: .voxDebugInject)) { note in
            if canListen, let text = note.object as? String { evaluate(text, injected: true) }
        }
        #endif
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECENT").font(.bdMicro()).foregroundStyle(Color.bdMuted2)
                .padding(.leading, 4)
            ForEach(recent) { t in
                Button { onOpenTask(t.persistentModelID) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(t.isCompleted ? Color.bdGreen : Color.bdPrimary).frame(width: 6, height: 6)
                        Text(t.title)
                            .font(.bdBody()).foregroundStyle(t.isCompleted ? Color.bdMuted2 : .white)
                            .strikethrough(t.isCompleted).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.bdMuted2)
                    }
                    .padding(.vertical, 9).padding(.horizontal, 12)
                    .background(Color.bdCard).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24).padding(.top, 28)
    }

    // MARK: - Voice engine (mirrors AllTasksView; final-utterance only, no live partials)

    private func syncVoice() { if listeningActive { armVoice() } else { stopVoice() } }

    private func armVoice() {
        guard listeningActive else { return }
        voiceActive = true
        actionInFlight = false
        speech.stopRecording()
        scheduleArm(0)
    }

    private func scheduleArm(_ attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard voiceActive, listeningActive, !speaker.isSpeaking else { return }
            speech.onSilenceDetected = { evaluate(speech.transcript) }
            do {
                try speech.startRecording()
                BDLog.speech.log("home: mic armed (attempt \(attempt))")
            } catch {
                if attempt < 2 { scheduleArm(attempt + 1) }
            }
        }
    }

    private func stopVoice() {
        voiceActive = false
        speech.stopRecording()
    }

    /// On Home a spoken phrase is EITHER a navigation command (show/read/mute/new) or a task to
    /// capture. A recognized nav command navigates; anything else with real words is handed to the
    /// capture sheet to parse (so "remind me to call mom" on Home is captured, not silently ignored
    /// — the regression that made Home feel dead). Very short/no-word noise just keeps listening.
    private func evaluate(_ text: String, injected: Bool = false) {
        if injected { actionInFlight = false }   // QA inject (braindump://inject) runs even off-mic
        guard injected || voiceActive, !actionInFlight else { return }

        if let cmd = NavCommandMatcher.match(text) {
            actionInFlight = true
            speech.stopRecording()
            switch cmd {
            case .showTasks(let f): onShowTasks(f)
            case .newDump:          onMicTap()
            case .open:             onShowTasks(.all)   // can't reliably resolve one task from Home
            case .readTasks:        speaker.readTasks(allTasks, filter: .pending)
            case .mute:             handsFree = false; stopVoice()
            default:                actionInFlight = false; armVoice()   // goBack/complete/delete/reopen: n/a here
            }
            return
        }

        // Not a nav command → treat as a note to capture, if it has at least two words (so stray
        // one-word noise doesn't pop the capture sheet).
        let words = text.split { !($0.isLetter || $0.isNumber) }
        if words.count >= 2 {
            actionInFlight = true
            speech.stopRecording()
            onCaptureText(text)
        } else if !injected {
            armVoice()
        }
    }
}

// MARK: - Slide-in drawer

private struct DrawerView: View {
    let onAllTasks: () -> Void
    let onSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 60)

                Text("Menu")
                    .font(.bdMicro()).foregroundStyle(Color.bdMuted)
                    .padding(.horizontal, 24).padding(.bottom, 20)

                drawerRow(icon: "checklist", label: "All Tasks", action: onAllTasks)
                Divider().background(Color.bdBorder).padding(.horizontal, 20)
                drawerRow(icon: "gearshape", label: "Settings", action: onSettings)

                Spacer()

                Text("voxdump")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.bdMuted2)
                    .padding(.horizontal, 24).padding(.bottom, 48)
            }
            .frame(width: 260)
            .background(Color.bdCard)
            .overlay(
                Rectangle()
                    .fill(Color.bdBorder)
                    .frame(width: 1),
                alignment: .trailing
            )

            Spacer()
        }
        .ignoresSafeArea()
    }

    private func drawerRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16)).foregroundStyle(Color.bdPrimary)
                    .frame(width: 24)
                Text(label).font(.bdBody()).foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .buttonStyle(.plain)
    }
}
