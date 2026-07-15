import Foundation

// Hands-free navigation/actions available on the Tasks list (the always-on listener
// in AllTasksView). Kept as a PURE, unit-testable layer so the whole "what did the user
// mean and which tasks does it hit" decision is provable without SwiftUI, SwiftData, or
// audio. Device logs drove this design: the old grammar could only express `<verb> <name>`,
// so "mark the first", "complete all", "complete all tasks created yesterday", and
// "call plumber is done" all fell through to a fuzzy title match on a bogus keyword
// ("first"/"all") and silently did nothing. See docs/MAINTENANCE.md §20.

/// WHICH tasks a command targets. Resolved against the live list by NavCommandResolver.
enum TaskSelector: Equatable {
    case ordinal(Int)            // 1-based position in the relevant list: "the second task" -> 2
    case last                    // "the last one"
    case all                     // "all" / "everything" / "them all"
    case createdOn(DayReference) // "created yesterday", "from today"
    case name(String)            // fuzzy title hint, resolved by TaskMatcher
}

/// A relative day used by date-scoped bulk commands.
enum DayReference: Equatable { case today, yesterday }

/// Which slice of the task list to display. Hashable so it can ride in a navigation route.
enum TaskFilter: Hashable { case all, pending, completed }

enum NavCommand: Equatable {
    case newDump              // start a brain dump
    case readTasks            // speak the list aloud
    case showTasks(TaskFilter) // navigate to / filter the task list (voice navigation from Home)
    case goBack               // pop to home / close the list
    case mute                 // turn off always-on listening
    case open(TaskSelector)      // open a single task
    case complete(TaskSelector)  // mark task(s) done
    case delete(TaskSelector)    // delete task(s) (caller must confirm first)
    case reopen(TaskSelector)    // reactivate a completed task
}

enum NavCommandMatcher {
    /// Map a (possibly partial) spoken transcript to a navigation command, or nil to
    /// keep listening. Whole-word matching so "backpack" != "back".
    static func match(_ text: String) -> NavCommand? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let words = t.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        guard !words.isEmpty else { return nil }
        let wordSet = Set(words)
        func has(_ ws: [String]) -> Bool { ws.contains { wordSet.contains($0) } }
        func phrase(_ ps: [String]) -> Bool { ps.contains { t.contains($0) } }

        // Mute / stop listening. Checked first so "stop" here never reads as a task verb.
        if phrase(["stop listening", "stop the mic", "turn off the mic", "turn off voice",
                   "stop voice", "hands free off", "stop hands free", "stop listen"])
            || has(["mute"]) { return .mute }

        // Go back / home / close-dismiss the current screen (the visible X or "‹ Tasks" control).
        // Leading "close" ("close", "close tasks", "close task page", "close this") means "leave
        // this screen", NOT "complete a task" — completion has its own verbs below. A "close" that
        // is not the first word (e.g. "complete close the deal") falls through to the verb loop.
        if phrase(["go back", "go home", "take me home", "back to home", "home screen"])
            || has(["home", "dismiss"])
            || words.first == "close"
            || (has(["back"]) && words.count <= 2) { return .goBack }

        // New brain dump / add a task (routes to the existing capture flow, which uses the LLM).
        if phrase(["new task", "add a task", "add task", "new dump", "brain dump", "braindump",
                   "add to my list", "new note", "start a dump", "capture a", "capture something",
                   "another task", "one more task"])
            || has(["dump"]) || (has(["capture"]) && !has(["task", "tasks"])) { return .newDump }

        // Read the list aloud.
        if phrase(["read my tasks", "read tasks", "read them", "read the list", "read my list",
                   "what's on my list", "whats on my list", "what do i have", "list my tasks"])
            || (has(["read"]) && has(["task", "tasks", "list", "them"])) { return .readTasks }

        // Show / navigate to the task list (voice navigation, primarily from Home). Checked before
        // the open verb so "show my tasks" navigates instead of trying to open a task called "tasks".
        let pendingWords = ["pending", "incomplete", "unfinished", "remaining", "outstanding", "to-do", "todo", "left", "open"]
        let doneWords = ["completed", "complete", "done", "finished", "checked"]
        // "show/view/see/list all [tasks]" -> the WHOLE list, NOT "open the first task". Must beat the
        // open-verb dispatch below (bug: "show all tasks" was matching open(.all) -> opened task #1),
        // and must NOT fire for "complete all"/"clear all" (those lead with a complete/delete verb).
        let mutateVerbs = ["complete", "completed", "finish", "finished", "done", "delete", "remove",
                           "clear", "trash", "wipe", "mark", "check", "reopen", "reactivate"]
        if has(["show", "view", "see", "list"]) && has(["all", "everything"]) && !has(mutateVerbs) {
            if has(doneWords) { return .showTasks(.completed) }
            if has(pendingWords) { return .showTasks(.pending) }
            return .showTasks(.all)
        }
        if phrase(["show tasks", "show my tasks", "show me my tasks", "show me the tasks", "my tasks",
                   "the task list", "task list", "go to tasks", "go to my tasks", "take me to tasks",
                   "take me to my tasks", "open tasks", "open my tasks", "open the task list",
                   "see my tasks", "view my tasks", "view tasks", "show the list", "show my list",
                   "pull up my tasks", "pull up tasks", "what are my tasks", "what tasks do i have"]) {
            if has(pendingWords) { return .showTasks(.pending) }
            if has(doneWords) { return .showTasks(.completed) }
            return .showTasks(.all)
        }
        // Bare filter phrases, including natural nav phrasings ("show pending", "go to pending",
        // "see done"). Placed before the verb loop / trailing-done parser so "go to pending" is a
        // navigation (not "open a task named pending") and "go to done" is a navigation (not
        // "complete <task>").
        if phrase(["show pending", "go to pending", "see pending", "view pending", "open pending",
                   "take me to pending", "pending tasks", "show my pending", "my pending tasks",
                   "show incomplete", "show remaining", "show outstanding", "what's pending",
                   "whats pending"]) { return .showTasks(.pending) }
        if phrase(["show completed", "go to completed", "go to done", "see completed", "see done",
                   "view completed", "view done", "open completed", "take me to done",
                   "completed tasks", "show done", "show finished", "show my completed",
                   "what's completed", "whats completed", "show done tasks"]) { return .showTasks(.completed) }

        // Reactivate / reopen a completed task. Checked before "complete" so "mark as not done"
        // and "reopen" are not swallowed by the completion verbs.
        if phrase(["not done", "not complete", "not finished", "mark as undone", "un-complete",
                   "put it back", "bring it back", "bring back"])
            || has(["reopen", "reactivate", "uncomplete", "uncheck", "unmark", "undo", "restore"]) {
            if let sel = selector(afterVerbs: ["reopen", "reactivate", "uncomplete", "uncheck",
                                               "unmark", "undo", "restore", "bring", "put"], words: words, text: t) {
                return .reopen(sel)
            }
            return .reopen(.last)
        }

        // Name-before-verb completion: "call plumber is done", "the report is finished".
        // The verb trails the task name, so the standard verb-then-name parse misses it.
        if let sel = trailingDoneSelector(words: words) { return .complete(sel) }

        // Earliest action verb wins. "open remove sumit paperwork" is an OPEN of the task named
        // "remove sumit paperwork" — the later delete-verb "remove" is part of the name, not the
        // command. Scanning left-to-right and taking the first verb encodes that (fixes bug 6).
        let completeVerbs: Set<String> = ["complete", "completed", "finish", "finished", "done",
                                          "check", "tick", "mark", "cross"]
        let deleteVerbs: Set<String> = ["delete", "remove", "trash", "erase", "clear",
                                        "wipe", "discard", "scrap"]
        let openVerbs: Set<String> = ["open", "show", "view", "goto", "see", "pull", "go"]
        for (i, w) in words.enumerated() {
            let rest = Array(words[(i + 1)...])
            if openVerbs.contains(w) {
                // An open verb with no concrete target ("show", "show the tasks", "open my tasks",
                // "view tasks") means "take me to the list", not "open a task named tasks". A real
                // target ("open groceries", "show call mom") still opens that task.
                if let sel = selectorFrom(rest: rest, text: t) { return .open(sel) }
                return .showTasks(.all)
            }
            let build: (TaskSelector) -> NavCommand
            if completeVerbs.contains(w) { build = NavCommand.complete }
            else if deleteVerbs.contains(w) { build = NavCommand.delete }
            else { continue }
            // Only the FIRST verb is the command; a bare complete/delete with no target keeps
            // listening (so "delete" alone is never destructive).
            return selectorFrom(rest: rest, text: t).map(build)
        }
        return nil
    }

    // MARK: - Selector parsing

    private static let ordinals: [String: Int] = [
        "first": 1, "1st": 1, "one": 1,
        "second": 2, "2nd": 2, "two": 2,
        "third": 3, "3rd": 3, "three": 3,
        "fourth": 4, "4th": 4, "four": 4,
        "fifth": 5, "5th": 5, "five": 5,
        "sixth": 6, "6th": 6, "six": 6,
        "seventh": 7, "7th": 7, "seven": 7,
        "eighth": 8, "8th": 8, "eight": 8,
        "ninth": 9, "9th": 9, "nine": 9,
        "tenth": 10, "10th": 10, "ten": 10
    ]

    /// Words that carry no identifying signal when building a name hint.
    private static let filler: Set<String> = ["the", "a", "an", "my", "me", "task", "tasks", "to",
                                              "up", "off", "item", "items", "of", "please", "for",
                                              "on", "as", "that", "it", "this", "now", "with", "and",
                                              "one", "ones", "them", "all", "everything"]

    /// Parse everything after the first matched verb into a TaskSelector.
    /// Order of precedence: date filter > ordinal/last > all > name. Returns nil when the
    /// verb is absent or nothing meaningful follows (so a bare "delete" is never destructive).
    private static func selector(afterVerbs verbs: [String], words: [String], text t: String) -> TaskSelector? {
        guard let vi = words.firstIndex(where: { verbs.contains($0) }) else { return nil }
        let rest = Array(words[(vi + 1)...])
        return selectorFrom(rest: rest, text: t)
    }

    private static func selectorFrom(rest: [String], text t: String) -> TaskSelector? {
        let restSet = Set(rest)

        // 1. Date filter ("created yesterday", "from today", "added yesterday").
        //    Requires an explicit day word; "today" alone as trailing filler does not qualify
        //    unless paired with a created/added/from/on cue or a bulk marker.
        let hasDayCue = restSet.contains("yesterday") || restSet.contains("today")
        let hasDateVerb = !restSet.isDisjoint(with: ["created", "added", "made", "from", "on", "since"])
        if hasDayCue && (hasDateVerb || restSet.contains("all") || restSet.contains("everything")) {
            if restSet.contains("yesterday") { return .createdOn(.yesterday) }
            if restSet.contains("today") { return .createdOn(.today) }
        }

        // 2. Ordinal / last.
        if restSet.contains("last") || restSet.contains("final") || restSet.contains("bottom") { return .last }
        for w in rest { if let n = ordinals[w] { return .ordinal(n) } }
        // "number 2", "task 3", "#2"
        for w in rest { if let n = Int(w), n >= 1, n <= 50 { return .ordinal(n) } }

        // 3. Bulk.
        if restSet.contains("all") || restSet.contains("everything") || restSet.contains("every") { return .all }

        // 4. Name hint (drop filler).
        let hint = rest.filter { !filler.contains($0) }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return hint.isEmpty ? nil : .name(hint)
    }

    /// "<name> is done" / "<name> done" / "<name> is complete/finished" -> complete(.name).
    /// Only fires when a completion cue is the LAST meaningful token, so it won't hijack
    /// "done" used mid-sentence.
    private static func trailingDoneSelector(words: [String]) -> TaskSelector? {
        let doneCues: Set<String> = ["done", "complete", "completed", "finished"]
        // Find a trailing done-cue, allowing a trailing "now"/"already".
        var end = words.count
        while end > 0, ["now", "already", "please"].contains(words[end - 1]) { end -= 1 }
        guard end >= 2, doneCues.contains(words[end - 1]) else { return nil }
        var nameEnd = end - 1
        // Drop a linking "is/are/'s/was" before the cue.
        if nameEnd > 0, ["is", "are", "was", "s", "has", "been"].contains(words[nameEnd - 1]) { nameEnd -= 1 }
        // Everything before is the task name — but only if there's no leading action verb
        // (those are handled by the normal verb-then-selector parse).
        let leadVerbs: Set<String> = ["complete", "finish", "mark", "check", "tick", "delete",
                                      "remove", "open", "show", "reopen"]
        let name = Array(words[0..<nameEnd])
        guard let first = name.first, !leadVerbs.contains(first) else { return nil }
        let hint = name.filter { !filler.contains($0) }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return hint.isEmpty ? nil : .name(hint)
    }
}

// MARK: - Resolver

/// A minimal, value-type view of a task for pure resolution/testing (no SwiftData).
struct TaskSnapshot: Equatable {
    let title: String
    let isCompleted: Bool
    let createdAt: Date
    init(title: String, isCompleted: Bool, createdAt: Date = Date(timeIntervalSince1970: 0)) {
        self.title = title
        self.isCompleted = isCompleted
        self.createdAt = createdAt
    }
}

/// Resolves a NavCommand's selector to the concrete indices it targets, given the task
/// list IN DISPLAY ORDER (AllTasksView shows most-recent-first). Selection universe by verb:
///   complete -> pending only     open -> pending, else any     reopen -> completed only
///   delete   -> pending for ordinal/last/name; ALL tasks for .all (clear the whole list)
/// Returns [] when nothing matches (caller speaks a "not found" hint).
enum NavCommandResolver {
    static func resolve(_ command: NavCommand, in tasks: [TaskSnapshot],
                        now: Date = Date(), calendar: Calendar = .current) -> [Int] {
        let pending = tasks.indices.filter { !tasks[$0].isCompleted }
        let completed = tasks.indices.filter { tasks[$0].isCompleted }

        switch command {
        case .newDump, .readTasks, .showTasks, .goBack, .mute:
            return []
        case .complete(let sel):
            return pick(sel, universe: pending, tasks: tasks, now: now, calendar: calendar)
        case .reopen(let sel):
            return pick(sel, universe: completed, tasks: tasks, now: now, calendar: calendar)
        case .open(let sel):
            let inPending = pick(sel, universe: pending, tasks: tasks, now: now, calendar: calendar)
            if !inPending.isEmpty { return Array(inPending.prefix(1)) }
            // Fall back to any task (e.g. opening a completed one by name).
            return Array(pick(sel, universe: Array(tasks.indices), tasks: tasks, now: now, calendar: calendar).prefix(1))
        case .delete(let sel):
            if case .all = sel { return Array(tasks.indices) }               // clear the whole list
            let inPending = pick(sel, universe: pending, tasks: tasks, now: now, calendar: calendar)
            if !inPending.isEmpty { return inPending }
            return pick(sel, universe: Array(tasks.indices), tasks: tasks, now: now, calendar: calendar)
        }
    }

    /// Whether resolving this command needs a destructive/bulk confirmation from the caller.
    static func isBulk(_ command: NavCommand) -> Bool {
        switch command {
        case .complete(let s), .delete(let s), .reopen(let s), .open(let s):
            switch s { case .all, .createdOn: return true; default: return false }
        default: return false
        }
    }

    private static func pick(_ sel: TaskSelector, universe: [Int], tasks: [TaskSnapshot],
                             now: Date, calendar: Calendar) -> [Int] {
        switch sel {
        case .ordinal(let n):
            guard n >= 1, n <= universe.count else { return [] }
            return [universe[n - 1]]
        case .last:
            return universe.last.map { [$0] } ?? []
        case .all:
            return universe
        case .createdOn(let day):
            let target: Date = day == .yesterday
                ? calendar.date(byAdding: .day, value: -1, to: now) ?? now
                : now
            return universe.filter { calendar.isDate(tasks[$0].createdAt, inSameDayAs: target) }
        case .name(let hint):
            let titles = universe.map { tasks[$0].title }
            guard let local = TaskMatcher.bestMatchIndex(hint: hint, titles: titles) else { return [] }
            return [universe[local]]
        }
    }
}

// MARK: - Home routing

/// The outcome of a finalized utterance heard on the Home screen. Pure and Equatable so the
/// Home <-> task-list routing is unit-testable without SwiftUI — in particular bug 3: a named
/// "open/show <task>" on Home must open that task, not dump to the full list.
enum HomeVoiceOutcome: Equatable {
    case showTasks(TaskFilter)   // navigate to / filter the task list
    case openTask(Int)           // open one task: index into the display-ordered tasks passed in
    case newDump                 // open the capture sheet
    case readTasks               // speak the pending tasks
    case mute                    // stop hands-free listening
    case capture(String)         // not a command — hand the phrase to capture to parse
    case ignore                  // one-word noise, or a command with no meaning on Home
}

enum HomeVoiceRouter {
    /// Decide what a finalized Home utterance should do, given the Home task list IN DISPLAY ORDER
    /// (most-recent first, matching HomeView's @Query sort). A named open/show resolves against that
    /// list via NavCommandResolver and yields .openTask(index); an unresolved name falls back to the
    /// full list (today's behavior for phrases we can't map to a task). This is exactly what
    /// AllTasksView.perform already does for .open — Home was the only surface ignoring the resolver.
    static func outcome(for text: String, tasks: [TaskSnapshot], now: Date = Date()) -> HomeVoiceOutcome {
        if let cmd = NavCommandMatcher.match(text) {
            switch cmd {
            case .showTasks(let f):
                return .showTasks(f)
            case .newDump:
                return .newDump
            case .open(let sel):
                if let i = NavCommandResolver.resolve(.open(sel), in: tasks, now: now).first {
                    return .openTask(i)
                }
                return .showTasks(.all)              // couldn't resolve a single task — show the list
            case .readTasks:
                return .readTasks
            case .mute:
                return .mute
            case .goBack, .complete, .delete, .reopen:
                return .ignore                       // not meaningful on Home
            }
        }
        // Not a nav command → capture it, if it has >= 2 words (stray one-word noise is ignored so
        // it doesn't pop the capture sheet).
        let words = text.split { !($0.isLetter || $0.isNumber) }
        return words.count >= 2 ? .capture(text) : .ignore
    }
}
