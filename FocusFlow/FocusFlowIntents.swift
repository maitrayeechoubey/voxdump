import AppIntents
import Foundation
import UIKit
import CoreFoundation

extension Notification.Name {
    static let braindumpOpen = Notification.Name("com.braindump.open")
    static let braindumpShowTasks = Notification.Name("com.braindump.showTasks")
}

// MARK: - Darwin cross-process notifications
// Darwin notifications work across process boundaries without App Groups.
// They are the most reliable way to signal the main app from an App Intent
// extension process.

private let kDarwinOpenMic   = "com.braindump.darwin.openMic"
private let kDarwinShowTasks = "com.braindump.darwin.showTasks"

// File-scope C-compatible callbacks (cannot capture any Swift state).
private let darwinOpenMicCallback: CFNotificationCallback = { _, _, _, _, _ in
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .braindumpOpen, object: nil)
    }
}
private let darwinShowTasksCallback: CFNotificationCallback = { _, _, _, _, _ in
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .braindumpShowTasks, object: nil)
    }
}

/// Call once at app startup (in FocusFlowApp.init) to start listening.
func registerDarwinObservers() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterAddObserver(center, nil, darwinOpenMicCallback,
                                    kDarwinOpenMic as CFString, nil, .deliverImmediately)
    CFNotificationCenterAddObserver(center, nil, darwinShowTasksCallback,
                                    kDarwinShowTasks as CFString, nil, .deliverImmediately)
    print("[braindump:darwin] observers registered")
}

private func postDarwin(_ name: String) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(name as CFString),
        nil, nil, true
    )
}

// MARK: - Brain Dump Intent

struct StartBrainDumpIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Voxdump"
    static var description = IntentDescription("Open Voxdump and start capturing your thoughts hands-free")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        print("[braindump:intent] StartBrainDumpIntent.perform() — signaling open mic")
        // Write a UUID so the @AppStorage KVO always fires, even if called twice in a row.
        // A plain bool flag silently skips KVO when the value hasn't changed.
        UserDefaults.standard.set(UUID().uuidString, forKey: "braindumpOpenToken")
        // Darwin notification: crosses process boundaries without App Groups.
        postDarwin(kDarwinOpenMic)
        // URL scheme: belt-and-suspenders for the in-process path.
        if let url = URL(string: "braindump://open") {
            await UIApplication.shared.open(url)
        }
        return .result()
    }
}

// MARK: - Show Tasks Intent

struct ShowTasksIntent: AppIntent {
    static var title: LocalizedStringResource = "Show My Tasks"
    static var description = IntentDescription("Open Voxdump and show your task list")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        print("[braindump:intent] ShowTasksIntent.perform() — signaling show tasks")
        UserDefaults.standard.set(UUID().uuidString, forKey: "braindumpShowTasksToken")
        postDarwin(kDarwinShowTasks)
        if let url = URL(string: "braindump://tasks") {
            await UIApplication.shared.open(url)
        }
        return .result()
    }
}

// MARK: - App Shortcuts (Siri phrases)
// Phrases MUST contain \(.applicationName) — prevents Siri routing to wrong app.

struct FocusFlowShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartBrainDumpIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Launch \(.applicationName)",
                "Start \(.applicationName)",
                "Brain dump in \(.applicationName)",
                "Start a vox dump in \(.applicationName)",
                "Capture my thoughts in \(.applicationName)",
                "Add tasks to \(.applicationName)",
                "Record tasks in \(.applicationName)"
            ],
            shortTitle: "Voxdump",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: ShowTasksIntent(),
            phrases: [
                "Show my tasks in \(.applicationName)",
                "Open my task list in \(.applicationName)",
                "What are my tasks in \(.applicationName)",
                "Show to do list in \(.applicationName)"
            ],
            shortTitle: "Show Tasks",
            systemImageName: "checklist"
        )
    }
}
