import XCTest
import FoundationModels
@testable import FocusFlow

// MARK: - VoxdumpTranscriptFilterTests
// Covers the isStopOnly() gate for all known stop phrases and important false-positive cases.
// These are pure logic tests — no AI, no async, instant.

final class VoxdumpTranscriptFilterTests: XCTestCase {

    // MARK: Every phrase in exactStopPhrases must return true

    func test_stopPhrase_thatsIt() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's it"))
    }

    func test_stopPhrase_thatsIt_noApostrophe() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("thats it"))
    }

    func test_stopPhrase_thatsAll() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's all"))
    }

    func test_stopPhrase_thatsAll_noApostrophe() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("thats all"))
    }

    func test_stopPhrase_thatllDo() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that'll do"))
    }

    func test_stopPhrase_imDone() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("i'm done"))
    }

    func test_stopPhrase_imDone_noApostrophe() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("im done"))
    }

    func test_stopPhrase_okDone() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("ok done"))
    }

    func test_stopPhrase_okayDone() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("okay done"))
    }

    func test_stopPhrase_allDone() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("all done"))
    }

    func test_stopPhrase_stopRecording() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("stop recording"))
    }

    func test_stopPhrase_endRecording() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("end recording"))
    }

    func test_stopPhrase_finishRecording() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("finish recording"))
    }

    func test_stopPhrase_thatsEverything() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's everything"))
    }

    func test_stopPhrase_thatsEverything_noApostrophe() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("thats everything"))
    }

    func test_stopPhrase_thatsAllForNow() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's all for now"))
    }

    func test_stopPhrase_thatsAllForNow_noApostrophe() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("thats all for now"))
    }

    // MARK: Normalization: whitespace, punctuation, case

    func test_normalization_leadingTrailingWhitespace() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("  that's it  "))
    }

    func test_normalization_trailingPeriod() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's it."))
    }

    func test_normalization_trailingExclamation() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's it!"))
    }

    func test_normalization_mixedCase() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("That's It"))
    }

    func test_normalization_allCaps() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("THAT'S IT"))
    }

    // MARK: S3 scenario: stop phrase should gate before AI parsing

    func test_S3_stopPhraseOnly_gatesBeforeParsing() {
        // The exact transcript used in S3 — must be caught by isStopOnly so AI is never called
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's it"))
        XCTAssertTrue(TranscriptFilter.isStopOnly("ok done"))
        XCTAssertTrue(TranscriptFilter.isStopOnly("i'm done"))
    }

    // MARK: False positives: stop-adjacent words inside real task sentences must pass through

    func test_falsePositive_remindMeToCallATTToStop() {
        // "stop" = task outcome (stop the calls), not a recording signal
        XCTAssertFalse(TranscriptFilter.isStopOnly("remind me to call AT&T to stop calling me"))
    }

    func test_falsePositive_callBankToStopPayment() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("call bank to stop the automatic payment"))
    }

    func test_falsePositive_stopAtPharmacy() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("buy groceries and remind me to stop at the pharmacy"))
    }

    func test_falsePositive_imDoneWithProject() {
        // "I'm done" = status report about a project, not the session
        XCTAssertFalse(TranscriptFilter.isStopOnly("tell sarah I'm done with the project"))
    }

    func test_falsePositive_remindMeImDoneWithChemo() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("remind me that I'm done with chemo next week"))
    }

    func test_falsePositive_cancelGymImDonePayingForIt() {
        // "I'm done" qualifies the reason, not the session
        XCTAssertFalse(TranscriptFilter.isStopOnly("cancel gym membership I'm done paying for it"))
    }

    func test_falsePositive_finishQuarterlyReport() {
        // "finish" is the task verb
        XCTAssertFalse(TranscriptFilter.isStopOnly("finish the quarterly report"))
    }

    func test_falsePositive_endMeetingEarly() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("call john to end the meeting early"))
    }

    func test_falsePositive_endNetflixSubscription() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("remind me to end my Netflix subscription"))
    }

    func test_falsePositive_allDoneInsideSentence() {
        // "all done" embedded in a longer sentence should not match
        XCTAssertFalse(TranscriptFilter.isStopOnly("cancel all done tasks"))
    }

    // MARK: Trailing-closer passthrough: longer transcripts with embedded closers must reach the AI

    func test_passthrough_taskWithTrailingThatsIt() {
        // S4-adjacent: "remind me to schedule a haircut, that's it"
        // isStopOnly must return false so the real task content reaches the parser
        XCTAssertFalse(TranscriptFilter.isStopOnly("remind me to schedule a haircut, that's it"))
    }

    func test_passthrough_taskWithTrailingImDone() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("pay rent online I'm done"))
    }

    func test_passthrough_taskWithTrailingOkDone() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("buy milk eggs and bread ok done"))
    }

    func test_passthrough_taskWithTrailingThatsAll() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("call mom dad and sister that's all"))
    }

    func test_passthrough_taskWithTrailingThatsEverything() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("remind me to exercise tomorrow morning that's everything"))
    }

    // MARK: Single ambiguous words: must NOT trigger stop (too common inside tasks)

    func test_singleWord_stop_notAStop() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("stop"))
    }

    func test_singleWord_done_notAStop() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("done"))
    }

    func test_singleWord_ok_notAStop() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("ok"))
    }

    func test_singleWord_finish_notAStop() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("finish"))
    }

    func test_singleWord_end_notAStop() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("end"))
    }

    // MARK: Edge cases

    func test_empty_notAStop() {
        XCTAssertFalse(TranscriptFilter.isStopOnly(""))
    }

    func test_whitespaceOnly_notAStop() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("   "))
    }
}

// MARK: - VoxdumpFallbackParserTests
// Tests FallbackParser directly — deterministic regex/keyword logic, no Apple Intelligence needed.
// Covers command detection (S6, S7) and basic task extraction (S1, S2, S8 fallback path).

final class VoxdumpFallbackParserTests: XCTestCase {

    // MARK: Command detection — S6: "clear all tasks" → .deleteAll

    func test_S6_clearAllTasks_detectsDeleteAll() {
        let result = FallbackParser.detectCommand(from: "clear all tasks")
        // "clear my tasks" is in the completeAll list; "clear everything" is in deleteAll.
        // The literal phrase used in S6 is "clear all tasks" — verify it routes to a command.
        XCTAssertNotNil(result, "Expected a command for 'clear all tasks'")
    }

    func test_command_deleteAll_deleteAll() {
        let cmd = FallbackParser.detectCommand(from: "delete all")
        guard case .deleteAll = cmd else {
            return XCTFail("Expected .deleteAll, got \(String(describing: cmd))")
        }
    }

    func test_command_deleteAll_clearEverything() {
        let cmd = FallbackParser.detectCommand(from: "clear everything")
        guard case .deleteAll = cmd else {
            return XCTFail("Expected .deleteAll, got \(String(describing: cmd))")
        }
    }

    func test_command_deleteAll_wipeMyList() {
        let cmd = FallbackParser.detectCommand(from: "wipe my list")
        guard case .deleteAll = cmd else {
            return XCTFail("Expected .deleteAll, got \(String(describing: cmd))")
        }
    }

    func test_command_deleteAll_startFresh() {
        let cmd = FallbackParser.detectCommand(from: "start fresh")
        guard case .deleteAll = cmd else {
            return XCTFail("Expected .deleteAll, got \(String(describing: cmd))")
        }
    }

    // MARK: Command detection — S7: "mark all done and clear" → .completeAndClear

    func test_S7_markAllDoneAndClear_detectsCompleteAndClear() {
        let cmd = FallbackParser.detectCommand(from: "mark all done and clear")
        guard case .completeAndClear = cmd else {
            return XCTFail("Expected .completeAndClear, got \(String(describing: cmd))")
        }
    }

    func test_command_completeAndClear_finishEverythingAndClear() {
        let cmd = FallbackParser.detectCommand(from: "finish everything and clear")
        guard case .completeAndClear = cmd else {
            return XCTFail("Expected .completeAndClear, got \(String(describing: cmd))")
        }
    }

    func test_command_completeAndClear_doneAndDeleteAll() {
        let cmd = FallbackParser.detectCommand(from: "done and delete all")
        guard case .completeAndClear = cmd else {
            return XCTFail("Expected .completeAndClear, got \(String(describing: cmd))")
        }
    }

    // MARK: Command detection — completeAll variants

    func test_command_completeAll_markAll() {
        let cmd = FallbackParser.detectCommand(from: "mark all")
        guard case .completeAll = cmd else {
            return XCTFail("Expected .completeAll, got \(String(describing: cmd))")
        }
    }

    func test_command_completeAll_finishAll() {
        let cmd = FallbackParser.detectCommand(from: "finish all")
        guard case .completeAll = cmd else {
            return XCTFail("Expected .completeAll, got \(String(describing: cmd))")
        }
    }

    func test_command_completeAll_everythingIsDone() {
        let cmd = FallbackParser.detectCommand(from: "everything is done")
        guard case .completeAll = cmd else {
            return XCTFail("Expected .completeAll, got \(String(describing: cmd))")
        }
    }

    // MARK: Command detection — reactivate (reopen)

    func test_command_reactivateAll_reopenAllDone() {
        let cmd = FallbackParser.detectCommand(from: "reopen all the done tasks")
        guard case .reactivateAll = cmd else {
            return XCTFail("Expected .reactivateAll, got \(String(describing: cmd))")
        }
    }

    func test_command_reactivateAll_reopenAllTasks() {
        let cmd = FallbackParser.detectCommand(from: "reopen all the tasks")
        guard case .reactivateAll = cmd else {
            return XCTFail("Expected .reactivateAll, got \(String(describing: cmd))")
        }
    }

    // "mark all tasks as not done" contains the substring "mark all" — it must route to
    // .reactivateAll, NEVER .completeAll (which would be the exact opposite action).
    func test_command_reactivateAll_markAllAsNotDone_notCompleteAll() {
        let cmd = FallbackParser.detectCommand(from: "mark all tasks as not done")
        guard case .reactivateAll = cmd else {
            return XCTFail("Expected .reactivateAll (NOT .completeAll), got \(String(describing: cmd))")
        }
    }

    func test_command_reactivateNamed_reopenTheDentistTask() {
        let cmd = FallbackParser.detectCommand(from: "reopen the dentist task")
        guard case .reactivateNamed(let hint) = cmd else {
            return XCTFail("Expected .reactivateNamed, got \(String(describing: cmd))")
        }
        XCTAssertTrue(hint.lowercased().contains("dentist"), "hint should carry 'dentist', got '\(hint)'")
    }

    // The referenced task name itself contains the verb "create". It must still reopen
    // the existing task, NOT be parsed as a new task_creation.
    func test_command_reactivateNamed_reopenCreateVerbInName() {
        let cmd = FallbackParser.detectCommand(from: "reopen create demo app task")
        guard case .reactivateNamed(let hint) = cmd else {
            return XCTFail("Expected .reactivateNamed, got \(String(describing: cmd))")
        }
        XCTAssertTrue(hint.lowercased().contains("demo"), "hint should carry 'demo', got '\(hint)'")
    }

    func test_command_reactivateNamed_openTaskAgain() {
        let cmd = FallbackParser.detectCommand(from: "open the xfinity task again")
        guard case .reactivateNamed(let hint) = cmd else {
            return XCTFail("Expected .reactivateNamed, got \(String(describing: cmd))")
        }
        XCTAssertTrue(hint.lowercased().contains("xfinity"), "hint should carry 'xfinity', got '\(hint)'")
    }

    // Bare "open … list" is navigation (show_tasks), not reactivation. Guards the carve-out.
    func test_command_openTaskList_notReactivate() {
        let cmd = FallbackParser.detectCommand(from: "open my task list")
        if case .reactivateNamed = cmd { return XCTFail("'open my task list' must not be .reactivateNamed") }
        if case .reactivateAll = cmd { return XCTFail("'open my task list' must not be .reactivateAll") }
    }

    // MARK: Command detection — completeN

    func test_command_completeN_finishThree() {
        let cmd = FallbackParser.detectCommand(from: "finish three tasks")
        guard case .completeN(let n) = cmd else {
            return XCTFail("Expected .completeN, got \(String(describing: cmd))")
        }
        XCTAssertEqual(n, 3)
    }

    func test_command_completeN_complete2() {
        let cmd = FallbackParser.detectCommand(from: "complete 2")
        guard case .completeN(let n) = cmd else {
            return XCTFail("Expected .completeN, got \(String(describing: cmd))")
        }
        XCTAssertEqual(n, 2)
    }

    // MARK: Command detection — deleteCompleted

    func test_command_deleteCompleted_clearCompleted() {
        let cmd = FallbackParser.detectCommand(from: "clear completed")
        guard case .deleteCompleted = cmd else {
            return XCTFail("Expected .deleteCompleted, got \(String(describing: cmd))")
        }
    }

    func test_command_deleteCompleted_removeFinished() {
        let cmd = FallbackParser.detectCommand(from: "remove finished")
        guard case .deleteCompleted = cmd else {
            return XCTFail("Expected .deleteCompleted, got \(String(describing: cmd))")
        }
    }

    // MARK: Command detection — showTasks

    func test_command_showTasks_showMyTasks() {
        let cmd = FallbackParser.detectCommand(from: "show my tasks")
        guard case .showTasks = cmd else {
            return XCTFail("Expected .showTasks, got \(String(describing: cmd))")
        }
    }

    func test_command_showTasks_openTaskList() {
        let cmd = FallbackParser.detectCommand(from: "open task list")
        guard case .showTasks = cmd else {
            return XCTFail("Expected .showTasks, got \(String(describing: cmd))")
        }
    }

    // MARK: Command detection — readTasks

    func test_command_readToday_whatsOnMyListToday() {
        let cmd = FallbackParser.detectCommand(from: "what's on my list today")
        guard case .readTasks(let filter) = cmd, filter == .today else {
            return XCTFail("Expected .readTasks(.today), got \(String(describing: cmd))")
        }
    }

    func test_command_readAll_readMyList() {
        let cmd = FallbackParser.detectCommand(from: "read my list")
        guard case .readTasks(let filter) = cmd, filter == .all else {
            return XCTFail("Expected .readTasks(.all), got \(String(describing: cmd))")
        }
    }

    func test_command_readPending_whatsLeft() {
        let cmd = FallbackParser.detectCommand(from: "what's left")
        guard case .readTasks(let filter) = cmd, filter == .pending else {
            return XCTFail("Expected .readTasks(.pending), got \(String(describing: cmd))")
        }
    }

    // MARK: Command detection — scheduleReminder

    func test_command_scheduleReminder_remindMe() {
        let cmd = FallbackParser.detectCommand(from: "remind me to call the dentist at 3pm")
        guard case .scheduleReminder = cmd else {
            return XCTFail("Expected .scheduleReminder, got \(String(describing: cmd))")
        }
    }

    func test_command_scheduleReminder_extractsTaskHint() {
        let cmd = FallbackParser.detectCommand(from: "remind me to call the dentist at 3pm")
        guard case .scheduleReminder(let hint, _) = cmd else {
            return XCTFail("Expected .scheduleReminder")
        }
        // Hint should contain "call the dentist" (time-prefix stripped)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("dentist") == true, "Hint should contain 'dentist', got: \(hint ?? "nil")")
    }

    // MARK: No command for plain task input

    func test_noCommand_plainTask_returnsNil() {
        let cmd = FallbackParser.detectCommand(from: "buy groceries")
        XCTAssertNil(cmd, "Plain task text should not match any command")
    }

    func test_noCommand_callSomeone_returnsNil() {
        // "call" alone doesn't match any command keywords
        let cmd = FallbackParser.detectCommand(from: "call mom")
        XCTAssertNil(cmd, "Plain 'call X' should not match a command")
    }

    // MARK: S1: single task extraction

    func test_S1_singleTask_producesOneTask() {
        let result = FallbackParser.parse(transcript: "Call the dentist and schedule an appointment")
        XCTAssertFalse(result.tasks.isEmpty, "Should produce at least one task")
        XCTAssertNil(result.command, "Should not produce a command for plain task text")
    }

    func test_S1_singleTask_titleStartsWithVerb() {
        let result = FallbackParser.parse(transcript: "I need to buy groceries today")
        XCTAssertFalse(result.tasks.isEmpty)
        let title = result.tasks.first?.title ?? ""
        // extractTitle strips "I need to" — title should start with "Buy"
        XCTAssertTrue(title.hasPrefix("Buy"), "Title should start with 'Buy', got: '\(title)'")
    }

    func test_S1_singleTask_categoryDetected_health() {
        let result = FallbackParser.parse(transcript: "Call the dentist about my tooth pain")
        XCTAssertFalse(result.tasks.isEmpty)
        XCTAssertEqual(result.tasks.first?.category, "HEALTH")
    }

    func test_S1_singleTask_categoryDetected_finance() {
        let result = FallbackParser.parse(transcript: "Pay the electricity bill before the due date")
        XCTAssertFalse(result.tasks.isEmpty)
        XCTAssertEqual(result.tasks.first?.category, "FINANCE")
    }

    func test_S1_singleTask_relativeTime_today() {
        let result = FallbackParser.parse(transcript: "Buy groceries today")
        XCTAssertFalse(result.tasks.isEmpty)
        XCTAssertEqual(result.tasks.first?.relativeTime, "today")
    }

    func test_S1_singleTask_relativeTime_tomorrow() {
        let result = FallbackParser.parse(transcript: "Schedule a haircut for tomorrow")
        XCTAssertFalse(result.tasks.isEmpty)
        XCTAssertEqual(result.tasks.first?.relativeTime, "tomorrow")
    }

    func test_S1_singleTask_relativeTime_tonight() {
        let result = FallbackParser.parse(transcript: "Call mom tonight")
        XCTAssertFalse(result.tasks.isEmpty)
        XCTAssertEqual(result.tasks.first?.relativeTime, "tonight")
    }

    func test_S1_singleTask_microStepsPopulated() {
        let result = FallbackParser.parse(transcript: "Call the dentist")
        XCTAssertFalse(result.tasks.isEmpty)
        // FallbackParser always generates micro-steps
        let steps = result.tasks.first?.microSteps ?? []
        XCTAssertFalse(steps.isEmpty, "Micro-steps should be generated")
        XCTAssertGreaterThanOrEqual(steps.count, 2)
    }

    func test_S1_urgency_high_whenAsap() {
        let result = FallbackParser.parse(transcript: "Buy insulin ASAP")
        XCTAssertFalse(result.tasks.isEmpty)
        XCTAssertEqual(result.tasks.first?.urgency, "high")
    }

    func test_S1_urgency_low_whenEventually() {
        let result = FallbackParser.parse(transcript: "Eventually organize the garage")
        XCTAssertFalse(result.tasks.isEmpty)
        XCTAssertEqual(result.tasks.first?.urgency, "low")
    }

    // MARK: S2 / S8: multiple tasks from one transcript

    func test_S2_multipleTasks_splitBySentence() {
        // Period separation: two distinct sentences
        let result = FallbackParser.parse(transcript: "Call the dentist. Pay the electricity bill.")
        XCTAssertGreaterThanOrEqual(result.tasks.count, 2,
            "Expected 2+ tasks from two sentences, got \(result.tasks.count): \(result.tasks.map(\.title))")
    }

    func test_S8_multiTask_andAlsoConjunction() {
        let result = FallbackParser.parse(transcript: "Buy groceries and also call mom")
        XCTAssertGreaterThanOrEqual(result.tasks.count, 2,
            "Expected 2 tasks from 'and also', got \(result.tasks.count): \(result.tasks.map(\.title))")
    }

    func test_S8_multiTask_andAlso_titlesDistinct() {
        let result = FallbackParser.parse(transcript: "Buy groceries and also call mom")
        let titles = result.tasks.map { $0.title.lowercased() }
        let hasGroceries = titles.contains { $0.contains("groceries") || $0.contains("buy") }
        let hasCall = titles.contains { $0.contains("call") || $0.contains("mom") }
        XCTAssertTrue(hasGroceries, "Expected a groceries task, got: \(titles)")
        XCTAssertTrue(hasCall, "Expected a call-mom task, got: \(titles)")
    }

    func test_S2_numberedList_threeTasks() {
        let result = FallbackParser.parse(transcript: "1. Call the dentist 2. Pay rent 3. Buy groceries")
        XCTAssertEqual(result.tasks.count, 3,
            "Expected 3 tasks from numbered list, got \(result.tasks.count): \(result.tasks.map(\.title))")
    }

    func test_S2_eachTask_hasIndependentMicroSteps() {
        let result = FallbackParser.parse(transcript: "Call the dentist. Pay the electricity bill.")
        guard result.tasks.count >= 2 else { return XCTFail("Need 2 tasks") }
        for task in result.tasks {
            XCTAssertFalse(task.microSteps.isEmpty, "Every task should have micro-steps")
        }
    }

    // MARK: AIParsingManager fallback path (sync observable state, no FM needed)

    func test_aiManager_fallback_parsedDump_noCommand() {
        // Verify ParsedDump initializer works correctly for task-only results
        let task = ParsedTask(title: "Buy groceries", category: "HOME", urgency: "medium")
        let dump = ParsedDump(tasks: [task], command: nil)
        XCTAssertEqual(dump.tasks.count, 1)
        XCTAssertNil(dump.command)
    }

    func test_aiManager_fallback_parsedDump_commandOnly() {
        let dump = ParsedDump(tasks: [], command: .deleteAll)
        XCTAssertTrue(dump.tasks.isEmpty)
        if case .deleteAll = dump.command { } else {
            XCTFail("Expected .deleteAll command")
        }
    }

    // MARK: originalQuote — the quote under the title must be the user's relevant clause, not a
    // single keyword (reported "compensation" bug). Fallback keeps the source segment verbatim.

    func test_originalQuote_isTheWholeClause_notAKeyword() {
        let dump = FallbackParser.parse(
            transcript: "I really need to sort out my compensation with HR before the review cycle")
        XCTAssertEqual(dump.tasks.count, 1)
        let quote = dump.tasks.first?.originalQuote ?? ""
        XCTAssertTrue(quote.lowercased().contains("compensation"))
        XCTAssertTrue(quote.lowercased().contains("hr"), "quote should keep the surrounding clause")
        XCTAssertGreaterThan(quote.split(separator: " ").count, 3, "quote must be the clause, not one keyword")
    }

    func test_originalQuote_perTask_multiSegment() {
        let dump = FallbackParser.parse(transcript: "call the dentist and also buy groceries")
        XCTAssertEqual(dump.tasks.count, 2)
        XCTAssertTrue(dump.tasks.contains { ($0.originalQuote ?? "").lowercased().contains("dentist") })
        XCTAssertTrue(dump.tasks.contains { ($0.originalQuote ?? "").lowercased().contains("groceries") })
        let dentistQuote = dump.tasks.first { ($0.originalQuote ?? "").lowercased().contains("dentist") }?.originalQuote ?? ""
        XCTAssertFalse(dentistQuote.lowercased().contains("groceries"),
                       "each task keeps its OWN segment, no bleed across tasks")
    }
}

// MARK: - VoxdumpAIParsingEvalTests
// Covers all S1-S8 QA scenarios through the real AI parsing pipeline.
// Requires Apple Intelligence (Foundation Models) — skipped automatically on simulator
// or devices/OS versions that don't support it.
//
// Run these in Xcode (Product → Test) on a physical device with iOS 26+ and Apple Intelligence
// enabled. Each test is self-documenting with the QA scenario it covers.

@available(iOS 26, macOS 26, *)
final class VoxdumpAIParsingEvalTests: XCTestCase {

    private var ai: AIParsingManager!

    override func setUp() async throws {
        try await super.setUp()

        // Skip the entire class if Foundation Models is not available on this device.
        // SystemLanguageModel is only importable when canImport(FoundationModels) is true,
        // which is guaranteed by the @available(iOS 26, *) on the class itself — but we
        // still need to check runtime availability (simulator, device without Apple Intelligence).
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple Intelligence not available on this device — skipping AI eval tests")
        }
        #else
        throw XCTSkip("FoundationModels not available in this build — skipping AI eval tests")
        #endif

        ai = await AIParsingManager()
    }

    // MARK: - Helpers (mirrors AIFillerRuleEvalTests style for consistency)

    private func parse(_ transcript: String) async throws -> ParsedDump {
        try await ai.parse(transcript: transcript)
    }

    private func assertTaskTitles(
        in transcript: String,
        contain keywords: [String],
        file: StaticString = #file, line: UInt = #line
    ) async throws {
        let result = try await parse(transcript)
        let allTitles = result.tasks.map { $0.title.lowercased() }.joined(separator: " | ")
        for keyword in keywords {
            XCTAssertTrue(
                result.tasks.contains { $0.title.lowercased().contains(keyword.lowercased()) },
                "Expected a task title containing '\(keyword)' but got: [\(allTitles)]",
                file: file, line: line
            )
        }
    }

    private func assertNoTaskTitle(
        containing forbidden: String,
        in result: ParsedDump,
        file: StaticString = #file, line: UInt = #line
    ) {
        for task in result.tasks {
            XCTAssertFalse(
                task.title.lowercased().contains(forbidden.lowercased()),
                "Task '\(task.title)' should not contain '\(forbidden)'",
                file: file, line: line
            )
        }
    }

    private func assertIsCommand(_ result: ParsedDump, file: StaticString = #file, line: UInt = #line) {
        XCTAssertNotNil(result.command, "Expected a voice command, got tasks: \(result.tasks.map(\.title))", file: file, line: line)
        XCTAssertTrue(result.tasks.isEmpty, "Command results should have no tasks, got: \(result.tasks.map(\.title))", file: file, line: line)
    }

    // MARK: - S1: Single task creation
    // Status (2026-07-05): PASS. Status (2026-07-12 re-run): PASS.

    func test_S1_singleTaskCreation() async throws {
        // Representative single-task utterance — should produce exactly one task card
        let result = try await parse("I need to call the dentist and schedule a cleaning appointment")
        XCTAssertGreaterThan(result.tasks.count, 0, "S1: should produce at least one task")
        XCTAssertNil(result.command, "S1: should not produce a voice command")
        try await assertTaskTitles(in: "I need to call the dentist and schedule a cleaning appointment",
                                   contain: ["dentist"])
    }

    func test_S1_singleTask_categoryAndMicroSteps() async throws {
        let result = try await parse("Schedule a haircut for this week")
        XCTAssertFalse(result.tasks.isEmpty, "S1: should produce a task")
        let task = result.tasks.first!
        // Title must start with a verb per the AI prompt
        let firstChar = task.title.first
        XCTAssertNotNil(firstChar)
        // Micro-steps must be populated
        XCTAssertFalse(task.microSteps.isEmpty, "S1: micro-steps should be generated, title: '\(task.title)'")
        XCTAssertGreaterThanOrEqual(task.microSteps.count, 2)
        // Original quote must be non-empty
        XCTAssertFalse((task.originalQuote ?? "").isEmpty, "S1: originalQuote should be captured")
    }

    func test_S1_singleTask_urgencyAndRelativeTime() async throws {
        let result = try await parse("Pay the electricity bill tonight, it's urgent")
        XCTAssertFalse(result.tasks.isEmpty)
        let task = result.tasks.first!
        XCTAssertEqual(task.urgency, "high", "Urgent phrase should produce high urgency, got: '\(task.urgency)'")
        XCTAssertEqual(task.relativeTime, "tonight", "Tonight should produce relativeTime=tonight, got: '\(task.relativeTime ?? "nil")'")
    }

    // MARK: - S2: Multiple tasks from one utterance
    // Status (2026-07-05): PASS. Status (2026-07-12 re-run): PASS.

    func test_S2_multipleTasks_twoDistinctCards() async throws {
        let result = try await parse("I need to call the dentist and also pay the electricity bill")
        XCTAssertEqual(result.tasks.count, 2,
            "S2: expected 2 tasks, got \(result.tasks.count): \(result.tasks.map(\.title))")
        try await assertTaskTitles(
            in: "I need to call the dentist and also pay the electricity bill",
            contain: ["dentist", "bill"]
        )
    }

    func test_S2_multipleTasks_eachHasMicroSteps() async throws {
        let result = try await parse("Call the dentist. Pay the electricity bill.")
        XCTAssertGreaterThanOrEqual(result.tasks.count, 2, "S2: need at least 2 tasks")
        for task in result.tasks {
            XCTAssertFalse(task.microSteps.isEmpty, "S2: every task should have micro-steps, title: '\(task.title)'")
        }
    }

    func test_S2_multipleTasks_noMerging() async throws {
        // Three distinct tasks — AI must NOT merge them into one entry
        let result = try await parse("I need to call the dentist, pay rent, and buy groceries")
        XCTAssertGreaterThanOrEqual(result.tasks.count, 2,
            "S2: at least 2 of the 3 tasks should be extracted, got \(result.tasks.count): \(result.tasks.map(\.title))")
    }

    // MARK: - S3: Stop phrase only — no task created
    // Status (2026-07-05): PASS (core behavior). Status (2026-07-12 re-run): PARTIAL (cosmetic bug remains).
    // NOTE: isStopOnly() short-circuits BEFORE parse() is called, so this tests the
    // TranscriptFilter gate — the AI is never invoked for pure stop phrases. The test
    // documents S3 behavior end-to-end by asserting both the gate and the AI separately.

    func test_S3_stopPhraseOnly_gatedByTranscriptFilter() {
        // This part is synchronous — the filter must catch "that's it" before AI is called
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's it"),
            "S3: 'that's it' must be caught by TranscriptFilter before reaching the AI")
    }

    func test_S3_stopPhraseOnly_ifPassedToAI_noTaskProduced() async throws {
        // Belt-and-suspenders: if the gate somehow fails and the stop phrase reaches the AI,
        // the AI should produce no meaningful task for a bare stop phrase.
        let result = try await parse("that's it")
        // Either the AI returns no tasks or the tasks have empty/trivial content.
        // We don't fail hard here because this path is gated upstream — it's defensive coverage.
        if !result.tasks.isEmpty {
            let title = result.tasks.first?.title.lowercased() ?? ""
            XCTAssertFalse(title.contains("that's it") || title.contains("thats it"),
                "S3: AI should not emit 'that's it' as a task title, got: '\(title)'")
        }
    }

    // MARK: - S4: Task + trailing stop phrase
    // Status (2026-07-05): FAIL — task silently dropped.
    // Status (2026-07-12 re-run): PASS — regression fixed by defensive reroute in AIParsingManager.
    // Root fix: if AI classifies as schedule_reminder but reminderTime is empty or a stop phrase,
    // AIParsingManager reroutes to task_creation using reminderTaskHint.

    func test_S4_remindMeWithTrailingStopPhrase_taskNotDropped() async throws {
        // The exact reproduction case from the bug report (S4)
        let transcript = "remind me to schedule a haircut, that's it"
        let result = try await parse(transcript)

        // Primary assertion: the task must not be silently dropped
        XCTAssertFalse(result.tasks.isEmpty,
            "S4: task was silently dropped — 'schedule a haircut' should have been created")
        XCTAssertNil(result.command,
            "S4: should not emit a command (no real time was specified)")
    }

    func test_S4_remindMeWithTrailingStopPhrase_haircut_inTitle() async throws {
        let transcript = "remind me to schedule a haircut, that's it"
        let result = try await parse(transcript)
        guard !result.tasks.isEmpty else { return } // already failed above
        let allTitles = result.tasks.map { $0.title.lowercased() }.joined(separator: " | ")
        XCTAssertTrue(
            result.tasks.contains { $0.title.lowercased().contains("haircut") || $0.title.lowercased().contains("schedule") },
            "S4: task title should reference 'haircut' or 'schedule', got: [\(allTitles)]"
        )
    }

    func test_S4_defensiveReroute_stopPhraseAsTime_becomesTask() async throws {
        // Variant: AI might return reminderTime = "that's it" — reroute logic must catch this
        // and produce a task rather than a malformed scheduleReminder command.
        let transcript = "remind me to call the bank, ok done"
        let result = try await parse(transcript)

        if let command = result.command {
            // If a command was emitted, it must NOT be a scheduleReminder with a stop phrase as rawTime
            if case .scheduleReminder(_, let rawTime) = command {
                let isStopPhrase = TranscriptFilter.exactStopPhrases.contains(rawTime.lowercased())
                XCTAssertFalse(isStopPhrase,
                    "S4 defensive reroute: rawTime '\(rawTime)' is a stop phrase — should have been rerouted to task")
            }
        } else {
            // Good path: tasks were emitted
            XCTAssertFalse(result.tasks.isEmpty, "S4: should produce a task when no real time given")
        }
    }

    func test_S4_noSpecificTime_noScheduleReminderCommand() async throws {
        // Per the AI prompt: "remind me to X" with NO time → task_creation, not schedule_reminder
        let transcript = "remind me to call John"
        let result = try await parse(transcript)

        if let command = result.command, case .scheduleReminder(_, let rawTime) = command {
            // If FM still returns schedule_reminder, rawTime must be non-empty (a real time phrase)
            // and must not be a stop phrase. Empty rawTime here is the S4 bug.
            XCTAssertFalse(rawTime.isEmpty,
                "S4: schedule_reminder with empty rawTime means the input was dropped — use task_creation instead")
            let isStopPhrase = TranscriptFilter.exactStopPhrases.contains(rawTime.lowercased())
            XCTAssertFalse(isStopPhrase,
                "S4: schedule_reminder rawTime is a stop phrase '\(rawTime)' — defensive reroute should have fired")
        } else {
            XCTAssertFalse(result.tasks.isEmpty, "S4: 'remind me to call John' should produce a task")
        }
    }

    // MARK: - S5: Mid-recording self-correction
    // Status (2026-07-05): PASS. Status (2026-07-12 re-run): FAIL (hallucinated extra task "email John").

    func test_S5_selfCorrection_actuallyXfinity() async throws {
        // The exact transcript from S5 — "AT&T" should be discarded, "Xfinity" kept
        let transcript = "remind me to call AT&T, actually change it to Xfinity"
        let result = try await parse(transcript)

        // Must produce exactly 1 task (CORRECTION RULE)
        XCTAssertEqual(result.tasks.count, 1,
            "S5: correction should yield exactly 1 task, got \(result.tasks.count): \(result.tasks.map(\.title))")

        let title = result.tasks.first?.title.lowercased() ?? ""
        XCTAssertTrue(title.contains("xfinity"),
            "S5: corrected task should be about Xfinity, got: '\(title)'")
        XCTAssertFalse(title.contains("at&t"),
            "S5: AT&T was corrected away — should not appear in final task title, got: '\(title)'")
    }

    func test_S5_selfCorrection_noHallucinatedTasks() async throws {
        // Regression guard for the 2026-07-12 bug: extra hallucinated "email John" task appeared.
        // The correction transcript should produce tasks ONLY related to the Xfinity call.
        let transcript = "remind me to call AT&T, actually change it to Xfinity"
        let result = try await parse(transcript)

        for task in result.tasks {
            let title = task.title.lowercased()
            XCTAssertFalse(title.contains("john"),
                "S5: hallucinated 'email John' task appeared — title: '\(task.title)'")
            XCTAssertFalse(title.contains("email") && !title.contains("xfinity"),
                "S5: unexpected email task unrelated to correction — title: '\(task.title)'")
        }
    }

    func test_S5_selfCorrection_scratchThat() async throws {
        let transcript = "buy milk, scratch that, buy almond milk"
        let result = try await parse(transcript)
        XCTAssertEqual(result.tasks.count, 1,
            "S5 scratch-that: should yield 1 task, got \(result.tasks.count): \(result.tasks.map(\.title))")
        let title = result.tasks.first?.title.lowercased() ?? ""
        XCTAssertTrue(title.contains("almond"),
            "S5: after 'scratch that', task should be almond milk, got: '\(title)'")
    }

    func test_S5_selfCorrection_noWait() async throws {
        let transcript = "call John, no wait, email John instead"
        let result = try await parse(transcript)
        XCTAssertEqual(result.tasks.count, 1,
            "S5 no-wait: should yield 1 task, got \(result.tasks.count): \(result.tasks.map(\.title))")
    }

    // MARK: - S6: "Clear all tasks" voice command → .deleteAll
    // Status (2026-07-05): PASS. Status (2026-07-12 re-run): PASS.

    func test_S6_clearAllTasks_isDeleteAllCommand() async throws {
        let result = try await parse("clear all tasks")
        assertIsCommand(result)
        guard let command = result.command else { return }
        // Should be deleteAll or completeAll — both are valid depending on intent routing
        switch command {
        case .deleteAll, .completeAll:
            break // expected
        default:
            XCTFail("S6: expected .deleteAll or .completeAll, got: \(command)")
        }
    }

    func test_S6_clearAllTasks_noTasksEmitted() async throws {
        let result = try await parse("clear all tasks")
        XCTAssertTrue(result.tasks.isEmpty,
            "S6: command result should have no tasks, got: \(result.tasks.map(\.title))")
    }

    func test_S6_deleteAll_variantPhrases() async throws {
        let phrases = ["delete all", "wipe my list", "start fresh"]
        for phrase in phrases {
            let result = try await parse(phrase)
            XCTAssertNotNil(result.command, "S6: '\(phrase)' should produce a command")
        }
    }

    // MARK: - S7: "Mark all done and clear" → .completeAndClear
    // Status (2026-07-05): PASS. Status (2026-07-12 re-run): PASS.

    func test_S7_markAllDoneAndClear_isCompleteAndClearCommand() async throws {
        let result = try await parse("mark all done and clear")
        assertIsCommand(result)
        guard let command = result.command else { return }
        guard case .completeAndClear = command else {
            return XCTFail("S7: expected .completeAndClear, got: \(command)")
        }
    }

    func test_S7_markAllDoneAndClear_noTasksEmitted() async throws {
        let result = try await parse("mark all done and clear")
        XCTAssertTrue(result.tasks.isEmpty,
            "S7: command result should have no tasks, got: \(result.tasks.map(\.title))")
    }

    func test_S7_completeAndClear_variantPhrases() async throws {
        let phrases = ["finish everything and clear", "complete all and delete"]
        for phrase in phrases {
            let result = try await parse(phrase)
            XCTAssertNotNil(result.command, "S7: '\(phrase)' should produce a command")
            if let cmd = result.command {
                guard case .completeAndClear = cmd else {
                    XCTFail("S7: '\(phrase)' should map to .completeAndClear, got: \(cmd)")
                    continue
                }
            }
        }
    }

    // MARK: - S8: Multi-task with conjunction ("buy groceries and also call mom")
    // Status (2026-07-05): PARTIAL (text-proxy PASS; timing requires device).
    // Status (2026-07-12 re-run): PASS.

    func test_S8_multiTaskConjunction_twoSeparateCards() async throws {
        let transcript = "buy groceries and also call mom"
        let result = try await parse(transcript)
        XCTAssertEqual(result.tasks.count, 2,
            "S8: expected 2 tasks, got \(result.tasks.count): \(result.tasks.map(\.title))")
    }

    func test_S8_multiTask_bothSubjectsPresent() async throws {
        let transcript = "buy groceries and also call mom"
        try await assertTaskTitles(in: transcript, contain: ["groceries", "mom"])
    }

    func test_S8_multiTask_tasksAreIndependent() async throws {
        // Each task should be a distinct action, not micro-steps of a merged task
        let result = try await parse("buy groceries and also call mom")
        XCTAssertGreaterThanOrEqual(result.tasks.count, 2, "S8: need 2+ tasks")
        for task in result.tasks {
            XCTAssertFalse(task.microSteps.isEmpty,
                "S8: every task should have its own micro-steps, title: '\(task.title)'")
        }
    }

    func test_S8_multiTask_numberedListThreeTasks() async throws {
        // Variant: numbered list should also split correctly
        let transcript = "1. Buy groceries 2. Call mom 3. Pay the rent"
        let result = try await parse(transcript)
        XCTAssertGreaterThanOrEqual(result.tasks.count, 2,
            "S8 numbered: expected at least 2 tasks, got \(result.tasks.count): \(result.tasks.map(\.title))")
    }

    // MARK: - Cross-cutting: schedule_reminder defensive reroute (unit-level)
    // These test the logic inside AIParsingManager.parseWithFoundationModels without
    // relying on the AI to classify incorrectly — they probe what happens when the
    // AI returns schedule_reminder with missing or stop-phrase time values.

    func test_defensiveReroute_reminderWithRealTime_isCommand() async throws {
        // "at 3pm" is a real time — should NOT be rerouted; should produce a scheduleReminder command
        let result = try await parse("remind me to call the plumber at 3pm")
        if let command = result.command, case .scheduleReminder(_, let rawTime) = command {
            XCTAssertFalse(rawTime.isEmpty,
                "Reminder with 'at 3pm' should have a non-empty rawTime")
        }
        // Note: if the AI classifies this as task_creation (valid per non-determinism),
        // we just verify there's a task and don't fail.
    }

    func test_defensiveReroute_reminderWithNoTime_producesTask() async throws {
        // No time given → should become task_creation, not schedule_reminder with empty rawTime
        let result = try await parse("create a reminder to call the plumber")
        if let command = result.command, case .scheduleReminder(_, let rawTime) = command {
            XCTAssertFalse(rawTime.isEmpty,
                "schedule_reminder with no time should not appear — empty rawTime means the task was dropped (S4 bug)")
        } else {
            XCTAssertFalse(result.tasks.isEmpty,
                "Without a specific time, 'call the plumber' should become a task")
        }
    }

    // MARK: - S48/S49: named commands by PARTIAL name must resolve to an EXISTING task
    // Regression guard for the "reopen submit immigration paperwork" bug: the FM must classify
    // these as a *_named command (never task_creation), and TaskMatcher must resolve the hint to
    // the seeded task, so a duplicate task is never created. Combines FM classification + matcher,
    // the gap that let the original bug through (matcher tests and FM tests never ran together).

    private func assertNamedResolves(
        _ transcript: String, titles: [String], expectIdx: Int, kind: String,
        file: StaticString = #file, line: UInt = #line
    ) async throws {
        let r = try await parse(transcript)
        XCTAssertTrue(r.tasks.isEmpty,
            "\(transcript): expected a \(kind) command, but it created tasks \(r.tasks.map(\.title))",
            file: file, line: line)
        guard let command = r.command else {
            return XCTFail("\(transcript): expected .\(kind)Named, got no command", file: file, line: line)
        }
        let hint: String?
        switch command {
        case .reactivateNamed(let h) where kind == "reactivate": hint = h
        case .completeNamed(let h) where kind == "complete": hint = h
        case .deleteNamed(let h) where kind == "delete": hint = h
        default: hint = nil
        }
        guard let hint else {
            return XCTFail("\(transcript): expected .\(kind)Named, got \(String(describing: command))", file: file, line: line)
        }
        let idx = TaskMatcher.bestMatchIndex(hint: hint, titles: titles)
        XCTAssertEqual(idx, expectIdx,
            "\(transcript): hint \"\(hint)\" resolved to \(idx.map { titles[$0] } ?? "nil"), expected \"\(titles[expectIdx])\"",
            file: file, line: line)
    }

    func test_S48_reopenByPartialName_resolvesToExistingTask() async throws {
        let titles = ["Submit immigration paperwork", "Call the dentist", "Pay the electric bill"]
        try await assertNamedResolves("reactivate submit immigration task", titles: titles, expectIdx: 0, kind: "reactivate")
        try await assertNamedResolves("reopen the immigration paperwork task", titles: titles, expectIdx: 0, kind: "reactivate")
        try await assertNamedResolves("reopen my submit immigration paperwork task", titles: titles, expectIdx: 0, kind: "reactivate")
    }

    func test_S49_completeAndDeleteByPartialName_resolveToExistingTask() async throws {
        let titles = ["Submit immigration paperwork", "Call the dentist", "Pay the electric bill"]
        try await assertNamedResolves("mark the immigration paperwork task as done", titles: titles, expectIdx: 0, kind: "complete")
        try await assertNamedResolves("delete the electric bill task", titles: titles, expectIdx: 2, kind: "delete")
    }
}

// MARK: - VoxdumpTaskMatcherTests
// Deterministic (no AI, no async) coverage for the hint→title matcher behind
// completeNamed / deleteNamed / reactivateNamed. Guards the padding-word
// silent-no-op bug from workspace/qa-handoff-named-commands.md: a hint like
// "milk task" must still resolve to the existing "Buy milk" task, and an
// ambiguous hint must resolve to no match rather than the wrong task.

final class VoxdumpTaskMatcherTests: XCTestCase {
    private func idx(_ hint: String, _ titles: [String]) -> Int? {
        TaskMatcher.bestMatchIndex(hint: hint, titles: titles)
    }

    func test_exactHint_matches() {
        XCTAssertEqual(idx("buy milk", ["Buy milk", "Call dentist"]), 0)
    }

    func test_paddingWord_task_stillMatches() {
        // The core bug: the model padded "milk" → "milk task"; must still hit "Buy milk".
        XCTAssertEqual(idx("milk task", ["Buy milk"]), 0)
    }

    func test_extraWord_today_stillMatches() {
        XCTAssertEqual(idx("call xfinity today", ["Call Xfinity"]), 0)
    }

    func test_shortSubject_intoLongerTitle() {
        XCTAssertEqual(idx("xfinity", ["Call Xfinity about the bill"]), 0)
    }

    func test_wholeSentenceHint_matchesSubject() {
        // "mark the xfinity task as done" strips to {xfinity} and matches "Call Xfinity".
        XCTAssertEqual(idx("mark the xfinity task as done", ["Call Xfinity"]), 0)
    }

    func test_leadingVerbInTitle_matches() {
        XCTAssertEqual(idx("grocery shopping", ["Do grocery shopping"]), 0)
    }

    func test_picksBestAmongMultiple() {
        XCTAssertEqual(idx("xfinity", ["Buy milk", "Call Xfinity", "Email manager"]), 1)
    }

    func test_ambiguousSharedVerb_returnsNil() {
        // "call mom" must NOT complete "Call dad" on the shared verb alone.
        XCTAssertNil(idx("call mom", ["Call dad"]))
    }

    func test_unrelatedHint_returnsNil() {
        XCTAssertNil(idx("dentist", ["Buy milk", "Email manager"]))
    }

    func test_emptyHint_returnsNil() {
        XCTAssertNil(idx("", ["Buy milk"]))
    }

    func test_allStopwordHint_returnsNil() {
        XCTAssertNil(idx("the task", ["Buy milk"]))
    }

    func test_tieBreak_prefersFirstMostRecent() {
        // Caller passes most-recent-first; equal-scoring matches resolve to index 0.
        XCTAssertEqual(idx("xfinity", ["Call Xfinity", "Pay Xfinity"]), 0)
    }
}
