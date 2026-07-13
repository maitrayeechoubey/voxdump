import Foundation
import OSLog

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26, macOS 26, *)
@Generable
struct FFParsedDump {
    @Guide(description: """
        The user's intent. Exactly ONE of: task_creation, complete_all, complete_and_clear, complete_n, complete_named, delete_all, delete_named, delete_completed, reactivate_named, reactivate_all, show_tasks, read_today, read_pending, read_all, schedule_reminder. Choose per the system instructions. Viewing/listing/reading existing tasks is show_tasks or read_*, NEVER task_creation; past-tense "already did it" is complete_named; reopen/undo is reactivate_*.
        """)
    var intent: String

    @Guide(description: "Only for schedule_reminder: the raw time phrase from the user (e.g. 'at 3pm', 'in 30 minutes', 'tomorrow morning'). Empty string otherwise.")
    var reminderTime: String

    @Guide(description: "Only for schedule_reminder: what to remind the user about. Empty string if not specified.")
    var reminderTaskHint: String

    @Guide(description: "For complete_named, delete_named, or reactivate_named: the SHORT task subject the user referenced (1 to 4 words, e.g. 'xfinity', 'grocery shopping', 'rent', 'dentist'). Never the full sentence, never a command verb like 'mark'/'complete'/'delete', never an intent label. Empty string for all other intents.")
    var namedTaskHint: String

    @Guide(description: "Only when intent is complete_n: how many tasks to complete. Use 0 otherwise.")
    var commandCount: Int

    @Guide(description: """
        All extracted tasks when intent is task_creation. You MUST create one separate FFParsedTask \
        entry for EACH distinct task the user mentioned — if the user said 2 things, output 2 entries; \
        if 3 things, output 3 entries. Never merge multiple tasks into one entry. \
        Empty array only for command intents.
        """)
    var tasks: [FFParsedTask]
}

@available(iOS 26, macOS 26, *)
@Generable
struct FFParsedTask {
    @Guide(description: "Short action-verb-first title, max 8 words. Must start with a verb.")
    var title: String

    @Guide(description: "Category. Exactly one of: PERSONAL, WORK, HOME, FINANCE, HEALTH, ERRANDS.")
    var category: String

    @Guide(description: "Time reference. Exactly one of: today, tonight, tomorrow_morning, tomorrow, this_week. Empty string if none.")
    var relativeTime: String

    @Guide(description: "Urgency. Exactly one of: high, medium, low.")
    var urgency: String

    @Guide(description: "2 to 4 immediately actionable micro-steps. Each must start with an action verb.")
    var microSteps: [String]

    @Guide(description: "The exact phrase or sentence from the transcript that triggered this task extraction.")
    var originalQuote: String
}
#endif

@MainActor
final class AIParsingManager: ObservableObject {
    @Published var isProcessing = false
    @Published var parsingMode: ParsingMode = .unknown

    enum ParsingMode { case unknown, foundationModels, fallback }

    private let instructions = """
    You are an intent classifier and task extractor for an ADHD voice app. FIRST pick exactly ONE intent. THEN, only for task_creation, extract every task.

    INTENTS:
    - task_creation: NEW things the user still needs to do. Default when unsure. NEVER for viewing/listing existing tasks, and NEVER for a past-tense "already did it".
    - show_tasks: wants to SEE the list on screen: show/open/"pull up"/list/"list them all"/"list out"/"what are my tasks"/"what tasks do I have"/"what's on my list"/"what's on my plate"/"what do I have". The verb "list" and "what tasks.../what's on..." ALWAYS mean show_tasks, even right after mentioning creating tasks ("I asked you to create some tasks, now list them all" -> show_tasks). Prefer show_tasks when unsure show vs read. A real task plus a view clause ("add call mom and show my list") extracts only the real task(s); a view request with no real task is show_tasks.
    - read_today / read_pending / read_all: read aloud. today: "what's due today", "what do I have today". pending: "what's left", "what's still pending". all: "read everything", "read them back", "give me a rundown".
    - complete_all: mark ALL pending done ("mark all done", "I finished everything").
    - complete_and_clear: mark ALL done AND wipe the list ("mark all done and clear").
    - complete_n: complete a specific COUNT ("done with 3", "I finished two", "knock out the top three"). Put the number in commandCount.
    - complete_named: ONE existing task is finished, INCLUDING plain past-tense with NO command word ("just finished the laundry", "wrapped up the presentation", "the report is done", "I already paid rent", "spoke to my boss, cross that off", "I called Xfinity, mark it done"). "cross it off"/"cross that off"/"check that off" about a past action is complete_named. Short subject -> namedTaskHint.
    - reactivate_named: REOPEN / un-complete ONE already-done task ("reopen the grocery task", "open the X task again", "bring it back", "oops I marked it done by mistake, bring it back", "I didn't actually finish the report"). ALWAYS an existing done task, never a new one. Short subject -> namedTaskHint.
    - reactivate_all: reopen / un-complete ALL done tasks ("reopen all", "reopen all the done tasks", "undo all of them", "bring them all back"). OPPOSITE of complete_all; never route it to complete_all or delete_all. namedTaskHint empty.
    - delete_all: wipe the WHOLE list. Any of clear/delete/wipe/remove/trash/nuke applied to everything: "delete all", "clear all tasks", "clear all", "clear all the tasks", "clear everything", "clear my tasks", "wipe my list", "start fresh".
    - delete_named: delete ONE named task ("delete the Xfinity task", "trash the gym task", "clear the milk task"). "clear/delete/remove/trash the [X] task" is ALWAYS this existing task X, never a new task, even if X sounds like an item to buy. Subject -> namedTaskHint.
    - delete_completed: remove ONLY the completed tasks ("clear the finished ones", "clear the completed ones", "clear the done ones", "clear all the done tasks", "remove the done ones").
    - schedule_reminder: a timed reminder WITH a time the user ACTUALLY said ("at 3pm", "in 30 minutes", "tomorrow morning", "ping me at 3"). Put that exact time in reminderTime, the subject in reminderTaskHint. NEVER invent a time: if the message has no real time, it is task_creation. If the user mentions MORE THAN ONE thing to do, even if one says "remind me" with a time, it is task_creation (extract them ALL as tasks).

    DISAMBIGUATION (read carefully):
    - CLEAR/TRASH/WIPE = REMOVE, never complete. The verbs clear, delete, wipe, remove, trash, "get rid of", nuke ALWAYS mean a delete intent, NEVER complete_all or complete_named. "clear all the done tasks" / "clear the completed ones" -> delete_completed. "clear all tasks" / "clear everything" -> delete_all. "clear the [X] task" -> delete_named.
    - VIEW is not CREATE: any request to see/show/list/"list out"/"pull up"/open/read/"read back"/"tell me"/"what tasks.../what's on..."/"what do I have" about existing tasks is show_tasks or read_*, NEVER task_creation. Never fabricate a task named "list"/"show my list"/"my tasks".
    - PAST is not FUTURE: past-tense done ("finished/wrapped up/paid/called/...is done") -> complete_named. Future or imperative ("I need to...", "call Xfinity", "remind me to...") -> task_creation.
    - OPPOSITES, reopen is the opposite of complete: reopen, "open ... again", un-complete, uncomplete, "not done", "as not done", "mark as not done", "didn't finish", "bring back", undo all set an ALREADY-DONE task back to pending. One target -> reactivate_named; all -> reactivate_all. NEVER complete_* or delete_* for these. Watch the word "not": "mark the dentist task as not done" -> reactivate_named "dentist"; "mark all tasks as not done" -> reactivate_all. A verb inside the task name ("reopen create demo app task" -> reactivate_named "demo app") is part of the name. Bare "open my list" (no "again") -> show_tasks.
    - namedTaskHint = short subject only (1 to 4 words, no command verb, no "task"/"as done", never the intent name). Good: "xfinity", "grocery shopping", "rent".

    TASK EXTRACTION (task_creation only):
    FIRST silently COUNT how many distinct things the user needs to do. THEN output EXACTLY that many task entries, one per distinct action. Never merge two actions into one entry, never hide one as a micro-step of another, and never truncate the list. If you count 3, output 3; if you count 4, output 4. The connecting words do not matter, only the number of distinct actions: "and", commas, "also", "plus", "then" all separate items. "call the dentist and pay rent and buy groceries" -> 3. "X, Y, and Z" -> 3. "pay the electric bill and also pick up dry cleaning" -> 2. Infer the intended verb from terse or mis-transcribed speech instead of dropping it: "by milk and eggs" (ASR for buy) -> Buy milk, Buy eggs; "call the bank" -> Call the bank. Output zero tasks ONLY when there is genuinely no actionable content (pure filler like "um, never mind").
    For EACH task set:
    - title: action-verb-first, max 8 words ("Call the dentist", "Pay electric bill").
    - category: exactly one of PERSONAL, WORK, HOME, FINANCE, HEALTH, ERRANDS.
    - relativeTime: today/tonight/tomorrow_morning/tomorrow/this_week, or empty if none.
    - urgency: high/medium/low.
    - microSteps: 2 to 4 concrete, immediately actionable steps, each starting with a verb. For "Call the dentist": "Look up the dentist's number", "Call to book a cleaning", "Add the appointment to my calendar".
    - originalQuote: the exact phrase from the transcript that triggered this task.
    Dedup identical titles. Trailing closers ("that's it", "done", "all done") at the END are end-of-speech, not tasks, but keep them mid-sentence ("call AT&T to cancel"). On self-correction ("actually", "no wait", "scratch that", "instead", "I meant", "change it to") keep ONLY the final version ("buy milk, scratch that, almond milk" -> Buy almond milk).
    """

    func parse(transcript: String) async throws -> ParsedDump {
        isProcessing = true
        defer { isProcessing = false }

        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability {
                parsingMode = .foundationModels
                do { return try await parseWithFoundationModels(transcript) } catch {
                    BDLog.parsing.error("FoundationModels parse failed, using fallback: \(error, privacy: .public)")
                }
            }
        }
        #endif

        parsingMode = .fallback
        let lower = transcript.lowercased()
        if let command = FallbackParser.detectCommand(from: lower) {
            return ParsedDump(tasks: [], command: command)
        }
        return FallbackParser.parse(transcript: transcript)
    }

    /// Narrow, unambiguous "show me my existing tasks" phrases that never appear in genuine
    /// task dictation — strong enough to override even a fabricated non-empty task_creation
    /// (e.g. "create some tasks, now list them all"). Kept deliberately tight so a real
    /// compound like "add call mom and show me my list" still creates the task.
    static func isStrongViewRequest(_ transcript: String) -> Bool {
        let t = transcript.lowercased()
        let strong = [
            "list them all", "list them", "list everything",
            "list all the task", "list all my task", "list out all", "list out my",
            "what tasks do you have", "what tasks do i have"
        ]
        return strong.contains { t.contains($0) }
    }

    /// Guards against the model inventing a reminder time the user never said. True only if the
    /// reminderTime shares a concrete anchor (a digit, or a day/time-of-day word) with the transcript.
    static func timeActuallyPresent(_ rawTime: String, in transcript: String) -> Bool {
        let time = rawTime.lowercased(); let t = transcript.lowercased()
        if time.isEmpty { return false }
        if t.contains(time) { return true }                                  // exact phrase echoed
        let digits = time.filter { $0.isNumber }
        if !digits.isEmpty, digits.contains(where: { t.contains($0) }) { return true }
        let anchors = ["tomorrow", "tonight", "morning", "afternoon", "evening", "noon", "midnight",
                       "minute", "hour", "o'clock", "week", "monday", "tuesday", "wednesday",
                       "thursday", "friday", "saturday", "sunday"]
        return anchors.contains { time.contains($0) && t.contains($0) }
    }

    /// Heuristic backstop used only when the model returns task_creation with zero tasks:
    /// does the transcript look like a request to view/list/read existing tasks?
    static func looksLikeViewRequest(_ transcript: String) -> Bool {
        let t = transcript.lowercased()
        let phrases = [
            "show my task", "show me my task", "show me the list", "show the list",
            "list them", "list all", "list everything", "list out", "list my task",
            "pull up", "bring up my", "open my task", "open up my task", "open task list",
            "what tasks", "what task do", "what's on my list", "what's on my plate",
            "what do i have", "what did i add", "what's left", "what is left",
            "read them", "read my", "read me", "read everything", "read all",
            "tell me everything", "rundown", "go through my", "what's due", "what is due"
        ]
        return phrases.contains { t.contains($0) }
    }

    /// The on-device model reliably drops the "not" in "mark X as not done" and returns a
    /// completion, the exact opposite of the ask. The prompt teaches the correct mapping (see
    /// the OPPOSITES rule) yet the model still fails this every time, so we enforce the flip
    /// deterministically. Deliberately narrow to explicit un-completion phrasings so it only
    /// ever fires on a real "reopen this" request the model misread as "complete this".
    nonisolated static func negatesCompletion(_ transcript: String) -> Bool {
        let t = transcript.lowercased()
        let markers = ["not done", "as not done", "not complete", "not finished",
                       "as undone", "un-complete", "uncomplete", "incomplete", "not marked done"]
        return markers.contains { t.contains($0) }
    }

    /// True when the utterance leads with an unambiguous delete verb. Used to stop the model's
    /// occasional "clear ... -> complete_all" flip, which is the opposite (and wrong) action.
    /// None of these verbs ever legitimately mean "complete", so this only corrects mistakes.
    nonisolated static func leadsWithDeleteVerb(_ transcript: String) -> Bool {
        let t = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["clear ", "wipe ", "trash ", "delete ", "remove ", "nuke ", "get rid"].contains { t.hasPrefix($0) }
    }

    /// True only when the user means the ENTIRE list, never a specific task. Gates the destructive
    /// delete_all intent. It matches the EXACT object of the command (after stripping the leading
    /// delete verb), so a named delete like "delete the all-hands meeting task" can never trip it
    /// just because the task NAME contains "all"/"the list"/"my tasks". A false negative here is
    /// safe (it demotes to a named delete, which no-ops); a false positive would wipe everything.
    nonisolated static func mentionsEntireList(_ transcript: String) -> Bool {
        let full = transcript.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.!?,"))
        // Whole-utterance "start over" style intents (no task named).
        let intents: Set<String> = ["start over", "start fresh", "start from scratch", "clean slate",
                                     "reset", "clear the board", "clear the lot", "wipe the slate", "scrap it all"]
        if intents.contains(full) { return true }
        // Strip a leading delete/clear verb, then judge the OBJECT of the command.
        var obj = full
        for verb in ["delete all of ", "clear out ", "get rid of ", "delete ", "clear ", "wipe ",
                     "trash ", "remove ", "nuke ", "erase "] where obj.hasPrefix(verb) {
            obj = String(obj.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if obj.hasSuffix(" please") { obj = String(obj.dropLast(7)).trimmingCharacters(in: .whitespaces) }
        // EXACT global-quantifier objects. An exact match cannot collide with a "the <name> task"
        // delete, whose object always carries the specific name (e.g. "the all-hands meeting task").
        let wholeList: Set<String> = [
            "all", "all tasks", "all my tasks", "all the tasks", "all of them", "all of it",
            "all of my tasks", "all of the tasks", "them", "them all", "all of these", "it all",
            "everything", "every task", "every single task", "every single one", "everything on the list",
            "the whole list", "the entire list", "my whole list", "my entire list",
            "the whole thing", "the entire thing", "the list", "my list", "the tasks", "my tasks"
        ]
        // Exact match only. No prefix allowance: "delete every overdue task" / "delete everything
        // bagel" (a task named that) are SCOPED or named deletes, not the whole list, so they must
        // demote to a named delete (safe no-op) rather than wipe everything.
        return wholeList.contains(obj)
    }

    /// Apply the deterministic destructive-safety guards to the raw model intent. Pure and
    /// unit-tested (VoxdumpDestructiveGuardTests): these correct the model's worst mistakes,
    /// where it takes the opposite or an over-broad destructive action.
    nonisolated static func guardedIntent(_ rawIntent: String, transcript: String) -> String {
        var intent = rawIntent
        // Negation: "mark X as not done" is a reopen, never a completion.
        if negatesCompletion(transcript) {
            if intent == "complete_all" { intent = "reactivate_all" }
            else if intent == "complete_named" { intent = "reactivate_named" }
        }
        // Destructive-clear: a leading clear/wipe/trash/delete/remove/nuke is a delete, not a
        // completion; "... the done/completed tasks" scopes to completed only.
        if leadsWithDeleteVerb(transcript) {
            let t = transcript.lowercased()
            let scopedToCompleted = ["done task", "done one", "completed", "finished"].contains { t.contains($0) }
            if scopedToCompleted, intent == "complete_all" || intent == "delete_all" {
                intent = "delete_completed"
            } else if intent == "complete_all" {
                intent = "delete_all"
            } else if intent == "complete_named" {
                intent = "delete_named"
            }
        }
        // Destructive-scope: NEVER wipe the whole list unless the user actually said so. A delete
        // that names a specific subject stays a single named delete, so "remove the nicobar island
        // task" can never nuke a dozen unrelated tasks (the 2026-07-13 data-loss regression).
        if intent == "delete_all", !mentionsEntireList(transcript) {
            intent = "delete_named"
        }
        return intent
    }

    /// A reminder is schedulable only if it names a real clock time (a digit, or a time-of-day
    /// word). Pure dates ("today", "tomorrow", "this week", "friday") have no time-of-day and
    /// cannot become a notification, so they should be tasks (with a relative-time label) instead.
    static func hasClockTime(_ rawTime: String) -> Bool {
        let t = rawTime.lowercased()
        if t.range(of: "[0-9]", options: .regularExpression) != nil { return true }
        return ["morning", "tonight", "afternoon", "evening", "noon", "midnight", "o'clock", "minute", "hour"]
            .contains { t.contains($0) }
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    private func parseWithFoundationModels(_ transcript: String) async throws -> ParsedDump {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Classify intent and extract tasks: \"\(transcript)\"",
            generating: FFParsedDump.self
        )
        let parsed = response.content
        #if DEBUG
        // DEBUG builds keep content .public so on-device logarchive QA still works.
        BDLog.parsing.notice("FM parse — intent=\(parsed.intent, privacy: .public) namedHint=\(parsed.namedTaskHint, privacy: .public) reminderTime=\(parsed.reminderTime, privacy: .public) tasks=\(parsed.tasks.count, privacy: .public) transcript=\(transcript, privacy: .public)")
        #else
        // RELEASE: redact user speech + task hints so they never persist in a shipped device's logs.
        BDLog.parsing.notice("FM parse — intent=\(parsed.intent, privacy: .public) namedHint=\(parsed.namedTaskHint, privacy: .private) reminderTime=\(parsed.reminderTime, privacy: .private) tasks=\(parsed.tasks.count, privacy: .public) transcript=\(transcript, privacy: .private)")
        #endif
        // Deterministic destructive-safety guards (negation, destructive-clear, and the
        // never-wipe-the-whole-list scope guard) all live in guardedIntent: pure + unit-tested.
        let intent = Self.guardedIntent(parsed.intent, transcript: transcript)
        switch intent {
        case "complete_all":        return ParsedDump(tasks: [], command: .completeAll)
        case "complete_named":
            let hint = parsed.namedTaskHint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hint.isEmpty else { return ParsedDump(tasks: [], command: .completeN(1)) }
            return ParsedDump(tasks: [], command: .completeNamed(hint))
        case "complete_and_clear": return ParsedDump(tasks: [], command: .completeAndClear)
        case "complete_n":       return ParsedDump(tasks: [], command: .completeN(max(1, parsed.commandCount)))
        case "delete_all":       return ParsedDump(tasks: [], command: .deleteAll)
        case "delete_named":
            // A named delete with no resolvable subject must do NOTHING. It must NEVER fall back
            // to deleteAll (that once wiped a full list when the model dropped the subject of
            // "remove the X task"). Empty hint -> deleteNamed("") which no-ops in executeCommand.
            let hint = parsed.namedTaskHint.trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedDump(tasks: [], command: .deleteNamed(hint))
        case "delete_completed": return ParsedDump(tasks: [], command: .deleteCompleted)
        case "reactivate_named":
            let hint = parsed.namedTaskHint.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty hint: reopen the most-recently-completed task. Never fall back to a
            // completion here, which would be the exact opposite of what was asked.
            guard !hint.isEmpty else { return ParsedDump(tasks: [], command: .reactivateN(1)) }
            return ParsedDump(tasks: [], command: .reactivateNamed(hint))
        case "reactivate_all":   return ParsedDump(tasks: [], command: .reactivateAll)
        case "show_tasks":       return ParsedDump(tasks: [], command: .showTasks)
        case "read_today":       return ParsedDump(tasks: [], command: .readTasks(.today))
        case "read_pending":     return ParsedDump(tasks: [], command: .readTasks(.pending))
        case "read_all":         return ParsedDump(tasks: [], command: .readTasks(.all))
        case "schedule_reminder":
            let hint = parsed.reminderTaskHint.isEmpty ? nil : parsed.reminderTaskHint
            let rawTime = parsed.reminderTime.trimmingCharacters(in: .whitespacesAndNewlines)
            // Defense: AI sometimes misclassifies "remind me to X, that's it" as schedule_reminder
            // when there is no real time. If the returned time is empty or a known stop phrase,
            // reroute to task_creation using the hint so the input is never silently dropped.
            // A reminder needs a real CLOCK time. Empty, hallucinated, or date-only ("today",
            // "tomorrow", "this week") times cannot be scheduled, so route them to a visible task
            // (carrying a relative-time label) instead of a silently-failing reminder.
            let timeIsAbsent = rawTime.isEmpty ||
                TranscriptFilter.exactStopPhrases.contains(rawTime.lowercased()) ||
                !Self.timeActuallyPresent(rawTime, in: transcript) ||   // reject hallucinated times
                !Self.hasClockTime(rawTime)                             // date-only is a task, not a reminder
            if timeIsAbsent, let hint = hint, !hint.isEmpty {
                let lt = rawTime.lowercased()
                let rel: String? = lt.contains("tomorrow") ? "tomorrow"
                    : lt.contains("today") ? "today"
                    : lt.contains("week") ? "this_week" : nil
                return ParsedDump(tasks: [ParsedTask(
                    title: hint,
                    category: "PERSONAL",
                    relativeTime: rel,
                    urgency: "medium",
                    microSteps: ["Complete task"],
                    originalQuote: hint
                )], command: nil)
            }
            return ParsedDump(tasks: [], command: .scheduleReminder(taskHint: hint, rawTime: rawTime))
        default:
            // Strong view phrases ("list them all", "what tasks do you have") are never
            // genuine new-task content — honor them even if the model fabricated tasks.
            if Self.isStrongViewRequest(transcript) {
                BDLog.parsing.notice("strong view phrase on task_creation — routing to showTasks")
                return ParsedDump(tasks: [], command: .showTasks)
            }
            // Softer guard: model returned task_creation with NO tasks, but the transcript is
            // clearly a request to see/list/read tasks — show the list instead of dead-ending
            // on "I didn't catch any tasks". Same class as the empty-hint routing guards.
            if parsed.tasks.isEmpty, Self.looksLikeViewRequest(transcript) {
                BDLog.parsing.notice("empty task_creation on a view-like transcript — routing to showTasks")
                return ParsedDump(tasks: [], command: .showTasks)
            }
            return ParsedDump(tasks: parsed.tasks.map {
                ParsedTask(
                    title: $0.title,
                    category: $0.category.isEmpty ? "PERSONAL" : $0.category,
                    relativeTime: $0.relativeTime.isEmpty ? nil : $0.relativeTime,
                    urgency: $0.urgency.isEmpty ? "medium" : $0.urgency,
                    microSteps: $0.microSteps.isEmpty ? ["Complete the task"] : $0.microSteps,
                    originalQuote: $0.originalQuote.isEmpty ? nil : $0.originalQuote
                )
            })
        }
    }
    #endif
}
