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
    You are an intent classifier and task extractor for an ADHD voice app. Choose exactly ONE intent, then (only for task_creation) extract tasks.

    INTENTS:
    - task_creation: NEW things the user still needs to do. Default when unsure — but NEVER for viewing/listing existing tasks, and NEVER for a past-tense "already did it".
    - show_tasks: wants to SEE the list on screen: show/open/"pull up"/list/"list them all"/"list out"/"what are my tasks"/"what tasks do I have"/"what's on my list"/"what's on my plate"/"what do I have". The verb "list" and "what tasks…/what's on…" ALWAYS mean show_tasks, even right after mentioning creating tasks ("I asked you to create some tasks, now list them all" → show_tasks). Prefer show_tasks when unsure show vs read.
    - read_today / read_pending / read_all: read aloud. today: "what's due today", "what do I have today". pending: "what's left", "what's still pending". all: "read everything", "read them back", "give me a rundown".
    - complete_all: mark ALL pending done ("mark all done", "I finished everything").
    - complete_and_clear: mark ALL done AND wipe the list.
    - complete_n: complete a specific count ("done with 3", "I finished two", "knock out the top three").
    - complete_named: ONE existing task is finished — INCLUDING plain past-tense with NO command ("just finished the laundry", "wrapped up the presentation", "the report is done", "I already paid rent", "I called Xfinity, mark it done"). Short subject → namedTaskHint.
    - reactivate_named: REOPEN / un-complete ONE task ("reopen the grocery task", "open the X task again", "bring it back", "I didn't actually finish the report", "mark X as not done"). Always an EXISTING done task, never a new one. Short subject → namedTaskHint.
    - reactivate_all: reopen / un-complete ALL ("reopen all", "mark all as not done", "undo all of them", "bring them all back"). OPPOSITE of complete_all; never complete_all or delete_all here.
    - delete_all: wipe the WHOLE list ("delete all", "clear everything", "wipe my list"). Only for an explicit all/everything.
    - delete_named: delete ONE named task ("delete the Xfinity task", "clear the milk task"). "clear the [X] task" is ALWAYS this (an existing task X), never a new task, even if X sounds like an item to buy. Description → namedTaskHint.
    - delete_completed: remove ONLY completed tasks ("clear the finished ones", "clear the completed ones", "remove the done ones"). Never delete_all.
    - schedule_reminder: a timed reminder WITH a specific time the user ACTUALLY said ("at 3pm", "in 30 minutes", "tomorrow morning", "ping me at 3"). Put that exact time in reminderTime, the subject in reminderTaskHint. NEVER invent a time — if the message has no time, it is task_creation. More than one thing to do → task_creation (extract all, even if one has a time).

    RULES:
    - VIEW ≠ CREATE: any request to see/show/list/"list out"/"pull up"/open/read/"read back"/"tell me"/"what tasks…/what's on…/what do I have" about existing tasks is show_tasks or read_*, NEVER task_creation. Never fabricate a task named "list"/"show my list"/"my tasks".
    - PAST vs FUTURE: past-tense done ("finished/wrapped up/paid/called/…is done") → complete_named. Future/imperative ("I need to…", "call Xfinity", "remind me to…") → task_creation.
    - REOPEN is the opposite of complete: reopen/"open…again"/un-complete/"not done"/"bring back"/undo/"didn't finish" → reactivate_named (one) or reactivate_all (all), never complete_* or delete_*. A verb inside the task name ("reopen create demo app task" → reactivate_named "demo app") is part of the name, not a new task. Bare "open my list" (no "again") → show_tasks.
    - DESTRUCTIVE guard: delete_all ONLY for an explicit all/everything. Never send "undo"/"bring back"/"clear the finished/completed ones" to delete_all (→ reactivate_all or delete_completed).
    - namedTaskHint = short subject only (1–4 words, no command verb, no "task"/"as done", never the intent name). Good: "xfinity", "grocery shopping", "rent".

    TASK EXTRACTION (task_creation only): one entry per distinct action. Title verb-first ≤8 words; category PERSONAL/WORK/HOME/FINANCE/HEALTH/ERRANDS; relativeTime today/tonight/tomorrow_morning/tomorrow/this_week or empty; urgency high/medium/low; 2–4 verb-first micro-steps; originalQuote from the transcript.
    - Count actions, not sentences. "and"/commas/"also" separate items: "buy milk and call the dentist" → 2 (Buy milk; Call the dentist); "X, Y, and Z" → 3. Never merge or drop.
    - Compound with a view clause ("add call mom and show my list") → extract only the real task(s); never a task named "show my list"/"list them all". No real task + a view request → show_tasks.
    - Dedup identical titles. Trailing closers ("that's it", "done", "all done") are end-of-speech, not tasks — but keep them mid-sentence ("call AT&T to cancel"). On self-correction ("actually", "no wait", "scratch that", "instead", "I meant") keep ONLY the final version ("buy milk, scratch that, almond milk" → Buy almond milk).
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

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    private func parseWithFoundationModels(_ transcript: String) async throws -> ParsedDump {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Classify intent and extract tasks: \"\(transcript)\"",
            generating: FFParsedDump.self
        )
        let parsed = response.content
        BDLog.parsing.notice("FM parse — intent=\(parsed.intent, privacy: .public) namedHint=\(parsed.namedTaskHint, privacy: .public) reminderTime=\(parsed.reminderTime, privacy: .public) tasks=\(parsed.tasks.count, privacy: .public) transcript=\(transcript, privacy: .public)")
        switch parsed.intent {
        case "complete_all":        return ParsedDump(tasks: [], command: .completeAll)
        case "complete_named":
            let hint = parsed.namedTaskHint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hint.isEmpty else { return ParsedDump(tasks: [], command: .completeN(1)) }
            return ParsedDump(tasks: [], command: .completeNamed(hint))
        case "complete_and_clear": return ParsedDump(tasks: [], command: .completeAndClear)
        case "complete_n":       return ParsedDump(tasks: [], command: .completeN(max(1, parsed.commandCount)))
        case "delete_all":       return ParsedDump(tasks: [], command: .deleteAll)
        case "delete_named":
            let hint = parsed.namedTaskHint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hint.isEmpty else { return ParsedDump(tasks: [], command: .deleteAll) }
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
            let timeIsAbsent = rawTime.isEmpty ||
                TranscriptFilter.exactStopPhrases.contains(rawTime.lowercased()) ||
                !Self.timeActuallyPresent(rawTime, in: transcript)   // reject hallucinated times
            if timeIsAbsent, let hint = hint, !hint.isEmpty {
                return ParsedDump(tasks: [ParsedTask(
                    title: hint,
                    category: "PERSONAL",
                    relativeTime: nil,
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
