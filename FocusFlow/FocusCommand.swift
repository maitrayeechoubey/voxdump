import Foundation

// Spoken commands on the single-task detail screen (TaskFocusView). Pure and unit-testable,
// matching the ReviewCommand / NavCommand pattern. On the detail screen the only ordinals that
// make sense are STEPS (there is no task-list ordinal here), so "complete first" means "complete
// the first step". "back"/"go back" returns to the list (mirrors the on-screen "‹ Tasks" button);
// task-to-task movement uses "next" / "previous".
enum FocusCommand: Equatable {
    case next                 // go to the next task
    case previous             // go to the previous task
    case completeStep(Int)    // 1-based step ordinal; Int.max == "last step"
    case completeTask         // mark the whole task done
    case goBack               // return to the task list
}

enum FocusCommandMatcher {
    static func match(_ text: String) -> FocusCommand? {
        let t = text.lowercased()
        let words = t.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        let wordSet = Set(words)
        func word(_ ws: String...) -> Bool { ws.contains { wordSet.contains($0) } }
        func phrase(_ ps: String...) -> Bool { ps.contains { t.contains($0) } }

        // Return to the list. Checked first so "go back"/"back to tasks" is never read as "previous".
        // Includes "all tasks" phrasings ("go to all tasks", "take me to all tasks", "show all
        // tasks") — substring matching on "go to tasks" alone missed those.
        if phrase("go to tasks", "go to all tasks", "go to my tasks", "go to the list", "go to all",
                  "back to tasks", "back to all tasks", "back to the list", "take me to tasks",
                  "take me to all tasks", "take me to my tasks", "take me back", "show tasks",
                  "show all tasks", "show my tasks", "show me my tasks", "show the tasks",
                  "task list", "the task list", "go home", "go back")
            || word("back", "close", "exit") { return .goBack }

        // Task-to-task navigation.
        if word("next", "forward") || phrase("next task", "next one", "skip to next") { return .next }
        if word("previous", "prev") || phrase("previous task", "previous one", "one before") { return .previous }

        // Step vs whole-task completion. An ordinal present => a specific STEP; otherwise the whole task.
        let stepVerb = word("complete", "completed", "check", "checked", "mark", "marked",
                            "finish", "finished", "done", "do", "tick", "toggle")
            || phrase("check off", "cross off")
        if stepVerb || t.contains("step") {
            if let n = stepOrdinal(words: words, text: t) { return .completeStep(n) }
        }
        if word("complete", "completed", "finish", "finished", "done", "mark", "marked")
            || phrase("mark complete", "all done", "task complete", "task done", "i'm done", "im done",
                      "done with this", "mark it complete") { return .completeTask }

        return nil
    }

    // Deliberately no homophones ("to"/"too"/"for") — they are common words and would false-fire.
    private static let ordinalWords: [String: Int] = [
        "first": 1, "1st": 1, "one": 1,
        "second": 2, "2nd": 2, "two": 2,
        "third": 3, "3rd": 3, "three": 3,
        "fourth": 4, "4th": 4, "four": 4,
        "fifth": 5, "5th": 5, "five": 5,
        "sixth": 6, "6th": 6, "six": 6,
        "seventh": 7, "7th": 7, "seven": 7,
        "eighth": 8, "8th": 8, "eight": 8,
        "ninth": 9, "9th": 9, "nine": 9,
        "tenth": 10, "10th": 10, "ten": 10,
    ]

    private static func stepOrdinal(words: [String], text: String) -> Int? {
        if text.contains("last") { return Int.max }
        for w in words { if let n = ordinalWords[w] { return n } }
        for w in words { if let d = Int(w), d >= 1, d <= 50 { return d } }
        return nil
    }
}
