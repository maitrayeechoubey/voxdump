import Foundation

// Hands-free navigation/actions available on the Tasks list (the always-on listener
// in AllTasksView). Kept separate from CardReviewView's ReviewCommandMatcher and made
// unit-testable so regressions are caught, matching the app's matcher conventions.
//
// Name-bearing commands (open/complete/delete) return only the spoken HINT after the
// verb; the caller resolves it to a real task with TaskMatcher (which does its own
// filler/verb stripping and confidence threshold), and delete is always confirmed by
// the caller, so this matcher never authorizes a destructive action on its own.
enum NavCommand: Equatable {
    case newDump              // start a brain dump
    case readTasks            // speak the list aloud
    case goBack               // pop to home / close the list
    case mute                 // turn off always-on listening
    case open(String)         // open the task whose title best-matches the hint
    case complete(String)     // mark a task done
    case delete(String)       // delete a task (caller must confirm first)
}

enum NavCommandMatcher {
    /// Map a (possibly partial) spoken transcript to a navigation command, or nil to
    /// keep listening. Whole-word matching so "backpack" != "back".
    static func match(_ text: String) -> NavCommand? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let words = t.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        let wordSet = Set(words)
        func has(_ ws: [String]) -> Bool { ws.contains { wordSet.contains($0) } }
        func phrase(_ ps: [String]) -> Bool { ps.contains { t.contains($0) } }

        // Mute / stop listening. Checked first so "stop" here never reads as a task verb.
        if phrase(["stop listening", "stop the mic", "turn off the mic", "turn off voice",
                   "stop voice", "hands free off", "stop hands free", "stop listen"])
            || has(["mute"]) { return .mute }

        // Go back / home / close the list.
        if phrase(["go back", "go home", "take me home", "back to home", "home screen"])
            || has(["home", "close", "dismiss"])
            || (has(["back"]) && words.count <= 2) { return .goBack }

        // New brain dump / add a task (routes to the existing capture flow, which uses the LLM).
        if phrase(["new task", "add a task", "add task", "new dump", "brain dump", "braindump",
                   "add to my list", "new note", "start a dump", "capture a", "capture something"])
            || has(["dump", "capture"]) { return .newDump }

        // Read the list aloud.
        if phrase(["read my tasks", "read tasks", "read them", "read the list", "read my list",
                   "what's on my list", "whats on my list", "what do i have", "list my tasks"])
            || (has(["read"]) && has(["task", "tasks", "list", "them"])) { return .readTasks }

        // Complete a named task.
        if let hint = hint(after: ["complete", "completed", "finish", "finished", "done",
                                   "check", "tick", "mark"], in: words) {
            return .complete(hint)
        }
        // Delete a named task (caller confirms).
        if let hint = hint(after: ["delete", "remove", "trash", "erase", "clear"], in: words) {
            return .delete(hint)
        }
        // Open / view a named task.
        if let hint = hint(after: ["open", "show", "view", "go", "goto", "see", "pull"], in: words) {
            return .open(hint)
        }
        return nil
    }

    /// Words after the first matched verb, dropping small glue words, joined into a hint.
    /// nil when the verb is absent or nothing meaningful follows (so a bare "delete" with
    /// no name never returns a destructive command). TaskMatcher strips the rest.
    private static func hint(after verbs: [String], in words: [String]) -> String? {
        guard let vi = words.firstIndex(where: { verbs.contains($0) }) else { return nil }
        let filler: Set<String> = ["the", "a", "an", "my", "me", "task", "tasks", "to", "up",
                                   "off", "item", "of", "please", "for", "on", "as", "that",
                                   "it", "this", "now", "with", "and"]
        let rest = words[(vi + 1)...].filter { !filler.contains($0) }
        let hint = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return hint.isEmpty ? nil : hint
    }
}
