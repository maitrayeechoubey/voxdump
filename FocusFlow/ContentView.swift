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
                }
            )
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .allTasks:                AllTasksView()
                case .settings:               SettingsView()
                case .taskFocus(let id):       TaskFocusView(taskID: id)
                }
            }
        }
        .fullScreenCover(isPresented: $showBrainDump) {
            BrainDumpSheet(
                onComplete: {
                    showBrainDump = false
                    navPath = [.allTasks]
                },
                onCommand: { command in
                    handleVoiceCommand(command)
                }
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

    @State private var pulse: CGFloat = 1.0
    @State private var glowOpacity: CGFloat = 0.4

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

                // Center content
                VStack(spacing: 12) {
                    Text("Voxdump")
                        .font(.bdTitle()).foregroundStyle(.white)
                    Text("Open, speak, done.")
                        .font(.bdBody()).foregroundStyle(Color.bdMuted)
                }

                Spacer().frame(height: 56)

                // FAB with glow rings
                ZStack {
                    Circle()
                        .fill(Color.bdPrimary.opacity(0.06))
                        .frame(width: 260, height: 260)
                        .scaleEffect(pulse)
                        .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: pulse)

                    Circle()
                        .fill(Color.bdPrimary.opacity(0.10))
                        .frame(width: 200, height: 200)

                    Button(action: onMicTap) {
                        ZStack {
                            Circle()
                                .fill(Color.bdPrimary)
                                .frame(width: 148, height: 148)
                                .shadow(color: Color.bdPrimary.opacity(glowOpacity), radius: 36, x: 0, y: 0)
                                .shadow(color: Color.bdPrimary.opacity(0.25), radius: 16, x: 0, y: 8)
                            Image(systemName: "mic.fill")
                                .font(.system(size: 56, weight: .medium))
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

                Spacer()

                Text("Tap to start your vox dump")
                    .font(.bdCaption()).foregroundStyle(Color.bdMuted2)
                    .padding(.bottom, 48)
            }
        }
        .navigationBarHidden(true)
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
