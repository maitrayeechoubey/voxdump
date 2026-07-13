import SwiftUI
import SwiftData
import AppIntents

@main
struct FocusFlowApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FocusFlowShortcuts.updateAppShortcutParameters()
        registerDarwinObservers()
        // Notification permission is requested lazily the first time the user schedules a
        // reminder (see ContentView.handleVoiceCommand) so first launch does not stack three
        // system prompts (Speech + Mic + Notifications) at once.
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    guard url.scheme == "braindump" else { return }
                    print("[braindump:url] onOpenURL: \(url)")
                    switch url.host {
                    case "tasks":
                        NotificationCenter.default.post(name: .braindumpShowTasks, object: nil)
                    default:
                        // "open" or any other host → open mic
                        NotificationCenter.default.post(name: .braindumpOpen, object: nil)
                    }
                }
        }
        .modelContainer(for: [TaskItem.self, MicroStep.self])
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                UserDefaults.standard.set(Date(), forKey: "lastActiveDate")
            }
        }
    }
}
