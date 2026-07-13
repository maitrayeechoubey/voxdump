import Foundation
import OSLog

enum FallbackParser {

    // MARK: - Command detection

    static func detectCommand(from lower: String) -> ParsedDump.VoiceCommand? {
        // Reactivate (reopen) ALL tasks — must run FIRST. "mark all tasks as not done"
        // contains the substring "mark all", so without this it would be caught by the
        // complete-all rules below and do the exact OPPOSITE of what was asked.
        let reactivateAllPhrases = [
            "reopen all", "re-open all", "reopen everything", "re-open everything",
            "reopen the done", "reopen all the done", "reopen the tasks", "reopen my tasks",
            "reactivate all", "reactivate everything", "un-complete all", "uncomplete all",
            "un-complete everything", "uncomplete everything", "unmark all", "uncheck all",
            "bring back all", "bring all my tasks back", "mark all as not done",
            "mark all tasks as not done", "mark everything as not done", "all tasks as not done",
            "mark all not done", "mark all as incomplete", "mark everything as incomplete"
        ]
        if reactivateAllPhrases.contains(where: { lower.contains($0) }) { return .reactivateAll }

        // Reopen ONE named task phrased as "open the [X] task again".
        if lower.hasPrefix("open ") && lower.hasSuffix(" again") {
            let mid = String(lower.dropFirst("open ".count).dropLast(" again".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !mid.isEmpty { return .reactivateNamed(mid) }
        }

        // Compound: mark all done AND clear/delete — must check before individual cases
        let completeAndClearPhrases = [
            "mark all done and clear", "complete all and clear", "finish all and clear",
            "all done and clear", "mark all complete and delete", "complete everything and clear",
            "done with all and clear", "mark all finished and delete",
            "check off all and clear", "all tasks done and clear",
            "mark all done and delete", "finish everything and clear",
            "complete all and delete", "done and delete all", "all done and delete"
        ]
        if completeAndClearPhrases.contains(where: { lower.contains($0) }) { return .completeAndClear }

        // Named delete — one specific task. Must run BEFORE deleteAll / reminderTriggers
        // so "delete the Xfinity task" or "clear the [task]" doesn't fall into the wrong bucket.
        let namedDeletePrefixes = [
            "delete the ", "delete my ",
            "remove the ", "remove my ",
            "get rid of the ", "get rid of my ",
            "trash the ", "erase the ",
            "clear the "
        ]
        let namedDeleteGenericWords: Set<String> = [
            "all", "everything", "list", "tasks", "done", "completed", "finished",
            "all tasks", "the tasks", "my tasks", "my list", "the list",
            "completed tasks", "done tasks", "finished tasks", "whole list", "entire list"
        ]
        for prefix in namedDeletePrefixes {
            guard lower.hasPrefix(prefix) else { continue }
            var hint = String(lower.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip trailing noise so "delete the Xfinity task" → hint = "xfinity"
            for noiseSuffix in [" task", " tasks", " reminder", " entry", " item"] {
                if hint.hasSuffix(noiseSuffix) {
                    let stripped = String(hint.dropLast(noiseSuffix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !stripped.isEmpty { hint = stripped }
                    break
                }
            }
            guard !hint.isEmpty, !namedDeleteGenericWords.contains(hint) else { continue }
            return .deleteNamed(hint)
        }

        // Delete all tasks
        let deleteAllPhrases = [
            "delete all", "remove all", "erase all", "wipe all", "clear all",
            "delete everything", "remove everything", "clear everything",
            "wipe everything", "wipe my list", "clear my list", "clear the list",
            "start fresh", "start over", "reset my tasks", "reset the list",
            "delete my tasks", "remove my tasks", "empty the list", "trash all"
        ]
        if deleteAllPhrases.contains(where: { lower.contains($0) }) { return .deleteAll }

        // Delete completed tasks only
        let deleteCompletedPhrases = [
            "delete completed", "remove completed", "clear completed",
            "delete done", "remove done", "clear done",
            "archive completed", "clean up completed", "hide completed",
            "remove finished", "delete finished", "clear finished",
            "clear all done", "delete all done", "remove all done",
            "clear tasks that are done", "delete tasks that are done",
            "clear all tasks that are done", "clear all tasks which are done",
            "tasks marked done", "marked as done", "marked done",
            "clear the done", "remove the done", "delete the done"
        ]
        if deleteCompletedPhrases.contains(where: { lower.contains($0) }) { return .deleteCompleted }

        // Complete all tasks
        let completeAllPhrases = [
            "complete all", "mark all", "finish all", "done with all",
            "close all", "check off all", "check all off", "all tasks done",
            "all done", "all complete", "all finished", "mark everything",
            "finish everything", "complete everything", "check everything off",
            "everything is done", "everything done", "all tasks complete",
            "done with everything", "finished everything", "i'm done with all",
            "i finished all", "clear my tasks"
        ]
        if completeAllPhrases.contains(where: { lower.contains($0) }) { return .completeAll }

        // Complete N tasks
        let numberMap: [(String, Int)] = [
            ("one", 1), ("two", 2), ("three", 3), ("four", 4), ("five", 5),
            ("six", 6), ("seven", 7), ("eight", 8), ("nine", 9), ("ten", 10),
            ("1", 1), ("2", 2), ("3", 3), ("4", 4), ("5", 5),
            ("6", 6), ("7", 7), ("8", 8), ("9", 9), ("10", 10)
        ]
        let nVerbs = ["complete", "finish", "done with", "close", "mark done",
                      "check off", "did", "completed", "finished"]
        for verb in nVerbs {
            for (word, n) in numberMap {
                if lower.contains("\(verb) \(word)") || lower.contains("\(verb) the \(word)") {
                    return .completeN(n)
                }
            }
        }

        // "I'm done" / "I finished" with no other content — complete most recent task
        let singleDoneSignals = ["i'm done", "i am done", "i finished", "i completed",
                                  "just finished", "that's done", "got it done", "finished it",
                                  "done with it", "it's done", "it is done"]
        if singleDoneSignals.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) {
            return .completeN(1)
        }

        // Shared generic-word guard used by both reactivateNamed and completeNamed below
        let genericWords: Set<String> = ["all", "everything", "it", "this", "that", "them",
                                         "all tasks", "the tasks", "my tasks"]

        // Reactivate (un-complete) a specific task — must run BEFORE completeNamed so
        // "mark X as not done" doesn't get garbled by the done-suffix stripper below.
        let reactivateSuffixes = [" as not done", " as not complete", " as not finished",
                                   " as incomplete", " not done", " not complete", " not finished"]
        for prefix in ["mark the ", "mark my ", "mark "] {
            guard lower.hasPrefix(prefix) else { continue }
            let afterPrefix = String(lower.dropFirst(prefix.count))
            for suffix in reactivateSuffixes {
                if afterPrefix.hasSuffix(suffix) {
                    let hint = String(afterPrefix.dropLast(suffix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !hint.isEmpty && !genericWords.contains(hint) {
                        return .reactivateNamed(hint)
                    }
                }
            }
        }
        let reactivatePrefixes = [
            "reopen the ", "reopen my ", "reopen ",
            "re-open the ", "re-open my ", "re-open ",
            "reactivate the ", "reactivate my ", "reactivate ",
            "un-complete the ", "un-complete my ", "un-complete ",
            "uncomplete the ", "uncomplete my ", "uncomplete ",
            "bring back the ", "bring back my ", "bring back ",
            "unmark the ", "unmark my ", "unmark ",
            "uncheck the ", "uncheck my ", "uncheck ",
            "undo completing the ", "undo completing "
        ]
        for prefix in reactivatePrefixes {
            guard lower.hasPrefix(prefix) else { continue }
            let hint = String(lower.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !hint.isEmpty && !genericWords.contains(hint) {
                return .reactivateNamed(hint)
            }
        }

        // Complete a specific named task: "mark [X] as done", "I finished [X]", etc.
        // completeAll / completeN / singleDoneSignals are already handled above, so reaching here
        // means the phrase contains a specific task description rather than "all" or a number.
        let namedDoneSuffixes = [" as done", " as complete", " as finished", " done", " complete", " finished"]
        let namedMarkPrefixes = ["mark the ", "mark my ", "mark "]
        let namedCompletePrefixes = ["complete the ", "complete my ", "complete "]
        let namedFinishPrefixes = ["i finished the ", "i finished my ", "i finished ",
                                   "i completed the ", "i completed my ", "i completed ",
                                   "finished the ", "finished my ", "finished ",
                                   "completed the ", "completed my ", "completed "]
        let namedAllPrefixes = namedMarkPrefixes + namedCompletePrefixes + namedFinishPrefixes
        for prefix in namedAllPrefixes {
            guard lower.hasPrefix(prefix) else { continue }
            var hint = String(lower.dropFirst(prefix.count))
            for suffix in namedDoneSuffixes {
                if hint.hasSuffix(suffix) { hint = String(hint.dropLast(suffix.count)); break }
            }
            hint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hint.isEmpty && !genericWords.contains(hint) {
                return .completeNamed(hint)
            }
        }

        // Show task list
        let showTasksPhrases = ["show my tasks", "open task list", "open my tasks",
                                "show task list", "show to do", "show todo",
                                "what are my tasks", "view my tasks", "go to tasks",
                                "take me to tasks", "navigate to tasks", "show the list"]
        if showTasksPhrases.contains(where: { lower.contains($0) }) { return .showTasks }

        // Read tasks aloud
        let readTodayPhrases = ["what's due today", "what is due today", "what do i have today",
                                "read today's tasks", "read today tasks", "tasks for today",
                                "what's on my list today", "today's tasks"]
        if readTodayPhrases.contains(where: { lower.contains($0) }) { return .readTasks(.today) }

        let readAllPhrases = ["read all my tasks", "read all tasks", "read everything",
                              "read my list", "what are all my tasks", "read the list",
                              "tell me my tasks", "what's on my list", "list my tasks"]
        if readAllPhrases.contains(where: { lower.contains($0) }) { return .readTasks(.all) }

        let readPendingPhrases = ["what's left", "what is left", "read pending tasks",
                                  "read my pending", "what do i still need to do",
                                  "what haven't i done", "remaining tasks"]
        if readPendingPhrases.contains(where: { lower.contains($0) }) { return .readTasks(.pending) }

        // Schedule reminder — only if we can isolate a real time phrase. Otherwise fall
        // through so it becomes a normal task (never pass the whole transcript as rawTime,
        // which guarantees parseTime fails downstream).
        let reminderTriggers = ["remind me", "set a reminder", "set reminder",
                                "alert me", "notify me", "create a reminder"]
        if reminderTriggers.contains(where: { lower.contains($0) }) {
            #if DEBUG
            BDLog.reminder.debug("Reminder trigger matched in: \"\(lower, privacy: .public)\"")
            #else
            BDLog.reminder.debug("Reminder trigger matched in: \"\(lower, privacy: .private)\"")
            #endif
            guard let rawTime = extractTimePhrase(from: lower) else {
                BDLog.reminder.debug("No time phrase found — treating as a task, not a reminder")
                return nil   // no time → let it be parsed as a task (never a bogus reminder)
            }
            var taskHint: String? = nil
            // Patterns ordered longest-first to grab the most specific prefix
            let hintPrefixes = ["remind me to ", "remind me about ", "set a reminder to ",
                                "set a reminder for ", "remind me "]
            for kw in hintPrefixes {
                if let r = lower.range(of: kw) {
                    var hint = String(lower[r.upperBound...])
                    // Strip leading time words that crept in (e.g. "at 3pm to do X")
                    for timePfx in ["at ", "in "] {
                        if hint.hasPrefix(timePfx) {
                            // Strip up to the next "to " which introduces the actual task
                            if let toRange = hint.range(of: " to ") {
                                hint = String(hint[toRange.upperBound...])
                            } else {
                                hint = ""   // only a time, no task specified
                            }
                        }
                    }
                    // Strip trailing time clauses: " at 3pm", " in 30 minutes", etc.
                    for timeSuffix in [" at ", " in ", " tonight", " tomorrow", " this evening"] {
                        if let tr = hint.range(of: timeSuffix) { hint = String(hint[..<tr.lowerBound]) }
                    }
                    hint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !hint.isEmpty { taskHint = hint }
                    break
                }
            }
            #if DEBUG
            BDLog.reminder.debug("Reminder extracted — hint: \"\(taskHint ?? "nil", privacy: .public)\", rawTime: \"\(rawTime, privacy: .public)\"")
            #else
            BDLog.reminder.debug("Reminder extracted — hint: \"\(taskHint ?? "nil", privacy: .private)\", rawTime: \"\(rawTime, privacy: .private)\"")
            #endif
            return .scheduleReminder(taskHint: taskHint, rawTime: rawTime)
        }

        #if DEBUG
        BDLog.parsing.debug("FallbackParser: no command matched in: \"\(lower, privacy: .public)\"")
        #else
        BDLog.parsing.debug("FallbackParser: no command matched in: \"\(lower, privacy: .private)\"")
        #endif
        return nil
    }

    /// Extracts a human time phrase from a lowercased transcript, or nil if none present.
    /// Deliberately simple; mirrors the phrases NotificationManager.parseTime understands.
    static func extractTimePhrase(from lower: String) -> String? {
        // Relative day / time-of-day keywords (return the keyword itself as the phrase).
        let dayPhrases = ["tomorrow morning", "tomorrow afternoon", "tomorrow evening",
                          "tomorrow night", "this evening", "tonight", "tomorrow"]
        for p in dayPhrases where lower.contains(p) { return p }
        // "in <n> minutes/hours/days"
        if let r = lower.range(of: #"in \d+\s*(minutes?|mins?|hours?|days?)"#,
                               options: .regularExpression) {
            return String(lower[r])
        }
        // "at <n>[:mm][ am/pm]" e.g. "at 3", "at 3pm", "at 3:30", "at 9 pm"
        if let r = lower.range(of: #"at \d{1,2}(:\d{2})?\s*(am|pm)?"#,
                               options: .regularExpression) {
            return String(lower[r]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Task parsing

    static func parse(transcript: String) -> ParsedDump {
        let tasks = split(transcript)
            .compactMap(makeTask)
            .filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        return ParsedDump(tasks: tasks)
    }

    // MARK: - Splitting

    private static func split(_ text: String) -> [String] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Numbered list: "1. task one 2. task two" — must detect before sentence splitting
        // because ". " would otherwise shred "1. task" into ["1", "task 2", ...]
        if let numbered = splitNumberedList(cleaned), numbered.count >= 2 {
            return numbered
        }

        var parts: [String] = [cleaned]

        for sep in [". ", "! ", "? "] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        for sep in [", and also ", " and also ", ", oh and ", " oh and ",
                    ", also ", " also, ", " and then ", ", then ", " plus ",
                    " and I need to ", " and I have to ", " and I should "] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }

        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.split(separator: " ").count >= 2 }
    }

    // Splits "1. do X 2. do Y 3. do Z" into ["do X", "do Y", "do Z"].
    // Also handles ordinal words: "first do X second do Y".
    private static func splitNumberedList(_ text: String) -> [String]? {
        let nsText = text as NSString
        let length = nsText.length

        // Digit-dot pattern: matches "1. " "12. " etc.
        if let regex = try? NSRegularExpression(pattern: #"\b\d+\.\s+"#) {
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: length))
            if matches.count >= 2 {
                var parts: [String] = []
                for (i, match) in matches.enumerated() {
                    let start = match.range.upperBound
                    let end = i + 1 < matches.count ? matches[i + 1].range.lowerBound : length
                    if start < end {
                        let part = nsText.substring(with: NSRange(location: start, length: end - start))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !part.isEmpty { parts.append(part) }
                    }
                }
                if parts.count >= 2 { return parts }
            }
        }

        // Ordinal-word pattern: "first ... second ... third ..."
        let ordinals = ["first", "second", "third", "fourth", "fifth",
                        "sixth", "seventh", "eighth", "ninth", "tenth"]
        let lower = text.lowercased()
        let foundOrdinals = ordinals.filter { lower.contains(" \($0) ") || lower.hasPrefix("\($0) ") }
        if foundOrdinals.count >= 2 {
            var parts: [String] = []
            var remaining = text
            for (i, ord) in foundOrdinals.enumerated() {
                guard let range = remaining.range(of: ord, options: .caseInsensitive) else { continue }
                let after = String(remaining[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let nextOrd = i + 1 < foundOrdinals.count ? foundOrdinals[i + 1] : nil
                if let next = nextOrd, let nextRange = after.range(of: next, options: .caseInsensitive) {
                    let part = String(after[..<nextRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !part.isEmpty { parts.append(part) }
                    remaining = String(after[nextRange.lowerBound...])
                } else {
                    let part = after.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !part.isEmpty { parts.append(part) }
                }
            }
            if parts.count >= 2 { return parts }
        }

        return nil
    }

    // MARK: - Category detection

    private static func detectCategory(from lower: String) -> String {
        let work: [String] = ["meeting", "email", "slack", "report", "pull request", "deploy",
                              "standup", "jira", "ticket", "code review", "presentation",
                              "deadline", "colleague", "manager", "client", "sprint", "backlog", "office"]
        let finance: [String] = ["pay ", "payment", "bill", "invoice", "bank", "credit card",
                                 "transfer", "venmo", "paypal", "zelle", "tax", "insurance",
                                 "subscription", "budget", "loan", "mortgage", "rent"]
        let health: [String] = ["doctor", "dentist", "gym", "workout", "exercise", "prescription",
                                "medication", "appointment", "therapy", "therapist", "vet",
                                "hospital", "clinic", "refill"]
        let home: [String] = ["clean", "laundry", "dishes", "grocery", "groceries", "vacuum",
                              "mop", "trash", "garbage", "furniture", "repair", "plumber",
                              "electrician", "landlord", "lease", "apartment", "house"]
        let errands: [String] = ["pick up", "drop off", "post office", "dmv", "pharmacy",
                                 "return", "exchange", "refund", "ship", "deliver", "package",
                                 "store", "shop"]
        if work.contains(where: { lower.contains($0) })    { return "WORK" }
        if finance.contains(where: { lower.contains($0) }) { return "FINANCE" }
        if health.contains(where: { lower.contains($0) })  { return "HEALTH" }
        if home.contains(where: { lower.contains($0) })    { return "HOME" }
        if errands.contains(where: { lower.contains($0) }) { return "ERRANDS" }
        return "PERSONAL"
    }

    // MARK: - Task extraction

    private static func makeTask(from text: String) -> ParsedTask? {
        let lower = text.lowercased()
        let fillers = ["uh", "um", "so", "like", "you know", "basically", "okay", "right"]
        guard !lower.split(separator: " ").allSatisfy({ fillers.contains(String($0)) }) else { return nil }

        let title = extractTitle(from: text)
        guard !title.isEmpty else { return nil }

        return ParsedTask(
            title: title,
            category: detectCategory(from: lower),
            relativeTime: extractTime(from: lower),
            urgency: extractUrgency(from: lower),
            microSteps: generateSteps(for: title, context: lower)
        )
    }

    private static func extractTitle(from text: String) -> String {
        var s = text

        let leadFillers = [
            "i need to ", "i need ", "i have to ", "i've got to ", "i gotta ",
            "i should ", "i should probably ", "i must ", "remind me to ",
            "don't forget to ", "don't let me forget to ", "make sure to ",
            "remember to ", "uh, ", "um, ", "so, ", "oh, ", "okay, ",
            "and ", "also ", "plus "
        ]
        for f in leadFillers {
            while s.lowercased().hasPrefix(f) { s = String(s.dropFirst(f.count)) }
        }

        for ctx in [" tonight", " today", " tomorrow morning", " tomorrow",
                    " this week", " this weekend", " right now", " asap",
                    " before i forget", " urgently", " immediately"] {
            s = s.replacingOccurrences(of: ctx, with: "", options: .caseInsensitive)
        }

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        let result = s.split(separator: " ").prefix(8).joined(separator: " ")
        return result.prefix(1).uppercased() + result.dropFirst()
    }

    private static func extractTime(from lower: String) -> String? {
        if lower.contains("tonight") || lower.contains("this evening") { return "tonight" }
        if lower.contains("tomorrow morning")                           { return "tomorrow_morning" }
        if lower.contains("tomorrow")                                   { return "tomorrow" }
        if lower.contains("today") || lower.contains("right now")      { return "today" }
        if lower.contains("this week") || lower.contains("this weekend") { return "this_week" }
        return nil
    }

    private static func extractUrgency(from lower: String) -> String {
        let hi = ["before i forget", "asap", "urgent", "important", "immediately",
                  "tonight", "right now", "don't forget", "must"]
        let lo = ["eventually", "someday", "maybe", "probably should", "think about",
                  "at some point", "when i get a chance"]
        if hi.contains(where: { lower.contains($0) }) { return "high" }
        if lo.contains(where: { lower.contains($0) }) { return "low" }
        return "medium"
    }

    // MARK: - Micro-step generation

    private static func generateSteps(for title: String, context: String) -> [String] {
        let l = title.lowercased()

        if l.hasPrefix("call") || l.hasPrefix("phone") || l.hasPrefix("ring") ||
           context.contains("plumber") || context.contains("contractor") || context.contains("doctor") ||
           context.contains("dentist") || context.contains("vet") || context.contains("landlord") {
            return ["Find their phone number or contact info",
                    "Call and explain what you need",
                    "Note any next steps or appointment date"]
        }
        if l.hasPrefix("email") || l.hasPrefix("message") || l.hasPrefix("text") ||
           l.hasPrefix("reply") || l.hasPrefix("respond") || l.hasPrefix("send") {
            return ["Open your email or messaging app",
                    "Write a clear, short message",
                    "Send it — follow up in 2 days if no reply"]
        }
        if l.hasPrefix("write") || l.hasPrefix("draft") || l.hasPrefix("compose") {
            return ["Open a blank doc or notes app",
                    "Write a rough first version without self-editing",
                    "Review and clean it up before sending"]
        }
        if l.hasPrefix("pay") || l.hasPrefix("transfer") || l.hasPrefix("venmo") ||
           context.contains("rent") || context.contains("bill") || context.contains("invoice") ||
           context.contains("payment") || context.contains("subscription") {
            return ["Open your bank app or payment portal",
                    "Verify the amount and recipient",
                    "Pay and screenshot the confirmation"]
        }
        if l.hasPrefix("buy") || l.hasPrefix("order") || l.hasPrefix("pick up") ||
           l.hasPrefix("get") || l.hasPrefix("shop") || l.hasPrefix("purchase") {
            return ["Find the item online or in store",
                    "Add to cart or write it on your list",
                    "Complete the purchase"]
        }
        if l.hasPrefix("schedule") || l.hasPrefix("book") || l.hasPrefix("reserve") ||
           (l.hasPrefix("make") && (context.contains("appointment") || context.contains("reservation"))) {
            return ["Check your calendar for open slots",
                    "Book it and confirm the time",
                    "Set a 1-hour-before reminder on your phone"]
        }
        if l.hasPrefix("plan") || l.hasPrefix("arrange") {
            return ["List out everything that needs to happen",
                    "Put things in order and assign times",
                    "Share the plan with anyone who needs it"]
        }
        if l.hasPrefix("research") || l.hasPrefix("look up") || l.hasPrefix("find out") ||
           l.hasPrefix("google") || l.hasPrefix("search") || l.hasPrefix("check out") {
            return ["Open a browser or app",
                    "Search and skim the top 3 results",
                    "Write down the key fact or decision you needed"]
        }
        if l.hasPrefix("review") || l.hasPrefix("read") || l.hasPrefix("check") ||
           l.hasPrefix("look over") || l.hasPrefix("go through") {
            return ["Pull up the document or item to review",
                    "Read it in one focused sitting",
                    "Write one clear next action before you close it"]
        }
        if l.hasPrefix("fix") || l.hasPrefix("repair") || l.hasPrefix("debug") ||
           l.hasPrefix("resolve") || l.hasPrefix("troubleshoot") {
            return ["Reproduce the issue so you understand exactly what's broken",
                    "Apply the fix",
                    "Test that it works and nothing else broke"]
        }
        if l.hasPrefix("update") || l.hasPrefix("upgrade") || l.hasPrefix("install") ||
           l.hasPrefix("set up") || l.hasPrefix("configure") {
            return ["Back up anything that could be affected",
                    "Run the update or installation",
                    "Test that everything still works afterward"]
        }
        if l.hasPrefix("clean") || l.hasPrefix("tidy") || l.hasPrefix("declutter") ||
           l.hasPrefix("clear out") || l.hasPrefix("organize") {
            return ["Set a 15-minute timer so it feels manageable",
                    "Focus on one area or surface at a time",
                    "Stop when timer goes off — progress is progress"]
        }
        if l.hasPrefix("talk") || l.hasPrefix("discuss") || l.hasPrefix("tell") ||
           l.hasPrefix("ask") || l.hasPrefix("mention") || l.hasPrefix("follow up") {
            return ["Decide when and where you'll have this conversation",
                    "Write down 1-2 key points you want to make",
                    "Have it — then send a quick summary if needed"]
        }
        if l.hasPrefix("submit") || l.hasPrefix("file") || l.hasPrefix("upload") ||
           l.hasPrefix("send in") || l.hasPrefix("turn in") {
            return ["Gather everything required for the submission",
                    "Double-check it's complete and correct",
                    "Submit and save the confirmation or receipt"]
        }
        if l.hasPrefix("prepare") || l.hasPrefix("make") || l.hasPrefix("create") ||
           l.hasPrefix("build") || l.hasPrefix("put together") {
            return ["List the materials or info you'll need first",
                    "Work through it in one focused block",
                    "Review before sharing or using it"]
        }
        if l.hasPrefix("return") || l.hasPrefix("exchange") || l.hasPrefix("refund") {
            return ["Locate the receipt or order confirmation",
                    "Package the item if needed",
                    "Drop it off or ship it back with tracking"]
        }
        if l.hasPrefix("print") || l.hasPrefix("scan") || l.hasPrefix("copy") {
            return ["Open the file or locate the physical document",
                    "Print, scan, or copy it",
                    "Save or send the result immediately"]
        }

        // Smart generic fallback using the actual verb and task
        let words = title.split(separator: " ")
        let verb = words.first.map(String.init) ?? "Start"
        let rest = words.dropFirst().prefix(5).joined(separator: " ")
        let shortTask = rest.isEmpty ? title.lowercased() : "\(verb.lowercased()) \(rest.lowercased())"

        return ["Block 15 minutes and remove distractions",
                "Start: \(shortTask) — just begin, don't overthink it",
                "Mark it done when you finish"]
    }
}
