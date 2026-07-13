import Foundation
import SwiftData

@Model
final class TaskItem {
    var id: UUID
    var title: String
    var category: String
    var relativeTime: String?
    var urgency: String
    var isCompleted: Bool
    var createdAt: Date
    var dueDate: Date?
    var currentStepIndex: Int
    var originalQuote: String?
    @Relationship(deleteRule: .cascade) var microSteps: [MicroStep]

    init(title: String,
         category: String = "PERSONAL",
         relativeTime: String? = nil,
         urgency: String = "medium",
         originalQuote: String? = nil) {
        self.id = UUID()
        self.title = title
        self.category = category
        self.relativeTime = relativeTime
        self.urgency = urgency
        self.isCompleted = false
        self.createdAt = Date()
        self.currentStepIndex = 0
        self.originalQuote = originalQuote
        self.microSteps = []
        self.dueDate = TaskItem.resolveDate(from: relativeTime)
    }

    var dueLabel: String {
        guard let dueDate else { return relativeTime.flatMap { TaskItem.labelFor($0) } ?? "" }
        let cal = Calendar.current
        if cal.isDateInToday(dueDate) { return "Today" }
        if cal.isDateInTomorrow(dueDate) { return "Tomorrow" }
        let f = DateFormatter(); f.dateStyle = .short
        return f.string(from: dueDate)
    }

    var completedMicroStepCount: Int { microSteps.filter(\.isCompleted).count }

    var firstIncompleteStep: MicroStep? {
        microSteps.filter { !$0.isCompleted }.sorted { $0.order < $1.order }.first
    }

    var isInProgress: Bool {
        !isCompleted && completedMicroStepCount > 0
    }

    private static func labelFor(_ relativeTime: String) -> String? {
        switch relativeTime {
        case "today":            return "Today"
        case "tonight":          return "Tonight"
        case "tomorrow_morning": return "Tomorrow AM"
        case "tomorrow":         return "Tomorrow"
        case "this_week":        return "This week"
        default:                 return nil
        }
    }

    static func resolveDate(from relativeTime: String?) -> Date? {
        guard let t = relativeTime else { return nil }
        let cal = Calendar.current
        let now = Date()
        switch t {
        case "today":            return cal.startOfDay(for: now)
        case "tonight":          return cal.date(bySettingHour: 20, minute: 0, second: 0, of: now)
        case "tomorrow_morning": return cal.date(byAdding: .day, value: 1, to: now)
                                        .flatMap { cal.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
        case "tomorrow":         return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
        case "this_week":        return cal.date(byAdding: .day, value: 5, to: now)
        default:                 return nil
        }
    }
}

@Model
final class MicroStep {
    var id: UUID
    var text: String
    var isCompleted: Bool
    var order: Int

    init(text: String, order: Int) {
        self.id = UUID()
        self.text = text
        self.isCompleted = false
        self.order = order
    }
}

struct ParsedDump {
    let tasks: [ParsedTask]
    let command: VoiceCommand?

    init(tasks: [ParsedTask], command: VoiceCommand? = nil) {
        self.tasks = tasks
        self.command = command
    }

    enum VoiceCommand {
        case completeAll
        case completeAndClear        // mark all done + delete completed in one shot
        case completeN(Int)
        case completeNamed(String)   // mark a specific task done by fuzzy title match
        case deleteAll
        case deleteNamed(String)     // delete one specific task by fuzzy title match
        case deleteCompleted
        case reactivateNamed(String) // un-complete a specific task by fuzzy title match
        case reactivateAll           // un-complete (reopen) every completed task
        case reactivateN(Int)        // reopen the N most recently completed tasks
        case showTasks
        case readTasks(ReadFilter)
        case scheduleReminder(taskHint: String?, rawTime: String)

        enum ReadFilter { case today, pending, all }
    }
}

struct ParsedTask: Identifiable {
    let id = UUID()
    let title: String
    let category: String
    let relativeTime: String?
    let urgency: String
    let microSteps: [String]
    let originalQuote: String?

    init(title: String,
         category: String = "PERSONAL",
         relativeTime: String? = nil,
         urgency: String = "medium",
         microSteps: [String] = [],
         originalQuote: String? = nil) {
        self.title = title
        self.category = category
        self.relativeTime = relativeTime
        self.urgency = urgency
        self.microSteps = microSteps
        self.originalQuote = originalQuote
    }

    var timeLabel: String? {
        switch relativeTime {
        case "today":            return "Today"
        case "tonight":          return "Tonight"
        case "tomorrow_morning": return "Tomorrow AM"
        case "tomorrow":         return "Tomorrow"
        case "this_week":        return "This week"
        default:                 return nil
        }
    }
}
