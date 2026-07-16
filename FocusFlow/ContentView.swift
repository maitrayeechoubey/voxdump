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
                case .allTasks:                AllTasksView(initialFilter: tasksFilter, navPath: $navPath)
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

// MARK: - Home hero hints (data-driven so tests can verify every advertised phrase resolves)

/// A tappable hint shown on the Home hero. Each is also a real spoken command:
/// `VoxdumpNavCommandTests` asserts every `phrase` resolves through `HomeVoiceRouter` to its
/// `action`, so the on-screen copy can never silently drift from what the voice matcher understands.
/// Primary hints (task creation, the app's main job) render filled + icon'd; navigation hints render
/// as lighter outline pills.
struct HomeHint: Identifiable, Equatable {
    enum Action: Equatable { case capture; case show(TaskFilter) }
    let icon: String?
    let phrase: String
    let isPrimary: Bool
    let action: Action
    var id: String { phrase }
}

enum HomeHints {
    static let all: [HomeHint] = [
        HomeHint(icon: "plus.circle.fill", phrase: "add a to-do",            isPrimary: true,  action: .capture),
        HomeHint(icon: "checklist",        phrase: "create a task",          isPrimary: true,  action: .capture),
        HomeHint(icon: nil,                phrase: "show all pending tasks", isPrimary: false, action: .show(.pending)),
        HomeHint(icon: nil,                phrase: "show all tasks",         isPrimary: false, action: .show(.all)),
    ]
}

/// Minimal wrapping layout that centers each row. Used for the Home hero hint chips so they flow
/// onto new lines (and stay centered) rather than overflowing when the phrases are wide. iOS 16+.
private struct CenteredFlowLayout: Layout {
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0, totalHeight: CGFloat = 0, maxRowWidth: CGFloat = 0
        for size in sizes {
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + rowSpacing
                maxRowWidth = max(maxRowWidth, rowWidth)
                rowWidth = size.width; rowHeight = size.height
            } else {
                rowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, rowWidth)
        return CGSize(width: proposal.width ?? maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var rows: [[Int]] = [], current: [Int] = [], rowWidth: CGFloat = 0
        for i in subviews.indices {
            let w = sizes[i].width
            if !current.isEmpty && rowWidth + spacing + w > maxWidth {
                rows.append(current); current = [i]; rowWidth = w
            } else {
                current.append(i); rowWidth = current.count == 1 ? w : rowWidth + spacing + w
            }
        }
        if !current.isEmpty { rows.append(current) }

        var y = bounds.minY
        for row in rows {
            let rowW = row.reduce(CGFloat(0)) { $0 + sizes[$1].width } + spacing * CGFloat(max(0, row.count - 1))
            let rowH = row.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX + max(0, (maxWidth - rowW) / 2)
            for i in row {
                let s = sizes[i]
                subviews[i].place(at: CGPoint(x: x, y: y + (rowH - s.height) / 2),
                                  anchor: .topLeading, proposal: ProposedViewSize(width: s.width, height: s.height))
                x += s.width + spacing
            }
            y += rowH + rowSpacing
        }
    }
}

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
    @State private var pulse: CGFloat = 1.0

    // Recent shows the last 3 PENDING tasks only — completed ones don't belong on the landing page.
    private var recent: [TaskItem] { Array(allTasks.filter { !$0.isCompleted }.prefix(3)) }
    private var voiceSupported: Bool { VoiceEnv.supported }
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

                Text("Voxdump")
                    .font(.bdTitle()).foregroundStyle(.white)

                Spacer().frame(height: 28)

                // The listening indicator IS the hero now (the old giant mic was removed — voice is
                // always-on, so a tap-only mic was redundant). It shows live listening state and
                // teaches the primary action: say a to-do. See `listeningHero`.
                listeningHero

                if !recent.isEmpty { recentSection }

                Spacer()
            }
        }
        .navigationBarHidden(true)
        // NOTE: Home does NOT use the shared bottom ListeningBar — the enlarged `listeningHero`
        // above is its listening indicator. The other screens (Tasks, TaskFocus, Reentry, BrainDump)
        // keep the compact bottom bar unchanged.
        .onAppear { syncVoice() }
        .onDisappear { speech.stopListening(as: "home") }
        .onChange(of: canListen) { _, _ in syncVoice() }
        .onChange(of: handsFree) { _, _ in syncVoice() }
        .onChange(of: speaker.isSpeaking) { _, speaking in if !speaking { syncVoice() } }
        #if DEBUG
        // QA seam: only handle injected transcripts while Home is the foreground surface, so it
        // never double-fires with the Tasks list's observer.
        .onReceive(NotificationCenter.default.publisher(for: .voxDebugInject)) { note in
            if canListen, let text = note.object as? String { evaluate(text) }
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

    // MARK: - Listening hero (Home only)

    /// The enlarged listening indicator that replaced the giant mic. Always-on voice runs in the
    /// background; this card makes that visible (live transcript + status), leads with the PRIMARY
    /// function (turn speech into to-dos), and offers two rich, tappable starter hints. Tapping a
    /// hint (or anywhere the mic would have been) still opens capture, so the tap path survives.
    private var listeningHero: some View {
        let hearing = voiceSupported && listeningActive && speech.isRecording
        let muted = voiceSupported && !handsFree
        let live = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let showTranscript = hearing && !live.isEmpty
        // Mute visibility follows the same tested rule as the shared bar (ListeningBarControls).
        let controls = ListeningBarControls.resolve(voiceEnabled: voiceSupported, muted: muted,
                                                     hasMuteToggle: true, hasRecordAction: true)

        return VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.bdPrimary.opacity(0.06))
                    .frame(width: 132, height: 132)
                    .scaleEffect(pulse)
                    .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: pulse)
                Circle()
                    .fill((muted ? Color.bdMuted2 : (hearing ? Color.bdGreen : Color.bdPrimary)).opacity(0.14))
                    .frame(width: 96, height: 96)
                Image(systemName: muted ? "mic.slash.fill" : (hearing ? "waveform" : "mic.fill"))
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(muted ? Color.bdMuted : (hearing ? Color.bdGreen : Color.bdPrimary))
                    .symbolEffect(.variableColor.iterative, isActive: hearing)
                    .contentTransition(.symbolEffect(.replace))
            }

            VStack(spacing: 6) {
                Text(heroTopLine(muted: muted, showTranscript: showTranscript, transcript: live))
                    .font(.bdHeadline())
                    .foregroundStyle(showTranscript ? .white : (muted ? Color.bdMuted2 : (voiceSupported ? Color.bdGreen : .white)))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .animation(.easeOut(duration: 0.15), value: showTranscript)
                Text("Just say what's on your mind and I'll turn it into to-dos.")
                    .font(.bdBody())
                    .foregroundStyle(Color.bdMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)

            // Tappable hints: primary (creation) first, then navigation. Each is ALSO a real spoken
            // command (see HomeHints + VoxdumpNavCommandTests), so users can just say them without
            // tapping. They wrap and stay centered via CenteredFlowLayout.
            CenteredFlowLayout(spacing: 10, rowSpacing: 10) {
                ForEach(HomeHints.all) { hint in
                    heroChip(hint) { perform(hint.action) }
                }
            }
            .padding(.horizontal, 4)

            if controls.showMute {
                Button {
                    handsFree.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label(handsFree ? "Listening — tap to mute" : "Muted — tap to listen",
                          systemImage: handsFree ? "mic.fill" : "mic.slash.fill")
                        .font(.bdCaption())
                        .foregroundStyle(handsFree ? Color.bdMuted : Color.bdMuted2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(handsFree ? "Mute voice" : "Unmute voice")
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.bdCard)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(hearing ? Color.bdGreen.opacity(0.5) : Color.bdBorder, lineWidth: 1))
        )
        .padding(.horizontal, 24)
        .onAppear {
            pulse = 1.08
            onFirstAppear()
        }
    }

    private func heroTopLine(muted: Bool, showTranscript: Bool, transcript: String) -> String {
        if showTranscript { return "\u{201C}\(transcript)\u{201D}" }
        if !voiceSupported { return "Tap to add a to-do" }
        if muted { return "Muted" }
        return "Listening…"
    }

    private func perform(_ action: HomeHint.Action) {
        switch action {
        case .capture:     onMicTap()
        case .show(let f): onShowTasks(f)
        }
    }

    /// One hint chip. Primary (creation) chips are filled + icon'd; navigation chips are lighter
    /// outline pills. The phrase is shown quoted because it is literally what you can say.
    private func heroChip(_ hint: HomeHint, action: @escaping () -> Void) -> some View {
        Button {
            action()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 7) {
                if let icon = hint.icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .bold))
                }
                Text("\u{201C}\(hint.phrase)\u{201D}").font(.bdCaption())
            }
            .foregroundStyle(hint.isPrimary ? Color.white : Color.bdMuted)
            .padding(.vertical, hint.isPrimary ? 10 : 8)
            .padding(.horizontal, hint.isPrimary ? 14 : 13)
            .background(heroChipBackground(isPrimary: hint.isPrimary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hint.isPrimary ? "Start a task. Say or tap \(hint.phrase)" : "Say or tap \(hint.phrase)")
    }

    @ViewBuilder
    private func heroChipBackground(isPrimary: Bool) -> some View {
        if isPrimary {
            Capsule().fill(Color.bdPrimary.opacity(0.18))
                .overlay(Capsule().stroke(Color.bdPrimary.opacity(0.45), lineWidth: 1))
        } else {
            Capsule().fill(Color.bdCard2)
                .overlay(Capsule().stroke(Color.bdBorder, lineWidth: 1))
        }
    }

    // MARK: - Voice engine (single-owner coordinator in SpeechManager — no per-view arm loop)

    private func syncVoice() {
        if listeningActive && !speaker.isSpeaking {
            speech.listen(as: "home") { text in evaluate(text) }
        } else {
            speech.stopListening(as: "home")
        }
    }

    /// On Home a FINALIZED utterance is EITHER a navigation command or a task to capture. A nav
    /// command navigates; anything else with real words is handed to the capture sheet to parse (so
    /// "remind me to call mom" on Home is captured, not silently ignored). One-word noise is ignored.
    private func evaluate(_ text: String) {
        // Pure routing decision (unit-tested via HomeVoiceRouter). A named "open/show <task>" now
        // resolves against Home's own task list and opens that task — HomeView has @Query allTasks,
        // so it can resolve just like the Tasks page instead of dumping to the full list (bug 3).
        let snap = allTasks.map { TaskSnapshot(title: $0.title, isCompleted: $0.isCompleted, createdAt: $0.createdAt) }
        switch HomeVoiceRouter.outcome(for: text, tasks: snap) {
        case .showTasks(let f): onShowTasks(f)
        case .openTask(let i):  onOpenTask(allTasks[i].persistentModelID)   // pushes [.allTasks, .taskFocus(id)]
        case .newDump:          onMicTap()
        case .readTasks:        speaker.readTasks(allTasks, filter: .pending)
        case .mute:             handsFree = false          // onChange(handsFree) -> syncVoice -> stopListening
        case .capture(let t):   onCaptureText(t)           // opens the sheet, which supersedes Home's listener
        case .ignore:           break                      // goBack/complete/delete/reopen or one-word noise
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
