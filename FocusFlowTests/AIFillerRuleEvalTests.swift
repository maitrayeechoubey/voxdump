import XCTest
@testable import FocusFlow

/// Eval cases for the AI filler-rule: "ignore trailing conversational closers
/// that appear after real content, but preserve stop-adjacent words inside sentences."
///
/// These tests call the real AI (Foundation Models) and validate:
///   1. Tasks are extracted correctly from transcripts that contain stop-adjacent words
///   2. Trailing closers ("that's it", "ok done", "I'm done") are not emitted as tasks
///   3. Stop-adjacent words that are semantically part of a task are preserved in the title
///
/// Run these manually in Xcode (Product → Test) on a device with Apple Intelligence.
/// They are marked as requiring Foundation Models and will be skipped on simulator.
@available(iOS 26, macOS 26, *)
final class AIFillerRuleEvalTests: XCTestCase {

    private var ai: AIParsingManager!

    override func setUp() async throws {
        try await super.setUp()
        ai = await AIParsingManager()
    }

    // MARK: - Helpers

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
                "Expected a task containing '\(keyword)' but got: \(allTitles)",
                file: file, line: line
            )
        }
    }

    private func assertNoTaskTitle(
        in transcript: String,
        contains forbidden: String,
        file: StaticString = #file, line: UInt = #line
    ) async throws {
        let result = try await parse(transcript)
        for task in result.tasks {
            XCTAssertFalse(
                task.title.lowercased().contains(forbidden.lowercased()),
                "Task '\(task.title)' should not contain '\(forbidden)'",
                file: file, line: line
            )
        }
    }

    private func assertTaskCount(
        in transcript: String,
        expected count: Int,
        file: StaticString = #file, line: UInt = #line
    ) async throws {
        let result = try await parse(transcript)
        XCTAssertEqual(result.tasks.count, count,
            "Expected \(count) task(s) from '\(transcript)', got \(result.tasks.count): \(result.tasks.map(\.title))",
            file: file, line: line)
    }

    // MARK: - "stop" inside a sentence must survive as part of the task title

    func test_stopInsideSentence_attStopCalling() async throws {
        // The word "stop" is the desired outcome for the customer service call.
        // It must appear in the extracted task, not be stripped.
        try await assertTaskTitles(
            in: "remind me to call AT&T to stop calling me",
            contain: ["AT&T", "stop"]
        )
    }

    func test_stopInsideSentence_stopAtPharmacy() async throws {
        // "stop" = physical location visit
        try await assertTaskTitles(
            in: "buy groceries and stop at the pharmacy on the way home",
            contain: ["groceries", "pharmacy"]
        )
    }

    func test_stopInsideSentence_stopAutoPayment() async throws {
        try await assertTaskTitles(
            in: "call the bank to stop the automatic payment to Equinox",
            contain: ["bank", "stop"]
        )
    }

    func test_stopInsideSentence_stopSmoking() async throws {
        try await assertTaskTitles(
            in: "I need to stop smoking, schedule an appointment with the doctor",
            contain: ["doctor"]
        )
        // "stop smoking" could reasonably be its own task — either is acceptable
    }

    // MARK: - "done" inside a sentence must survive

    func test_doneInsideSentence_tellSarahDone() async throws {
        // "I'm done" describes the user's status on a project, not the recording session
        try await assertTaskTitles(
            in: "tell Sarah I'm done with the project proposal",
            contain: ["Sarah"]
        )
    }

    func test_doneInsideSentence_doneByFriday() async throws {
        try await assertTaskTitles(
            in: "finish the quarterly report, it needs to be done by Friday",
            contain: ["report"]
        )
    }

    func test_doneInsideSentence_donePayingGym() async throws {
        try await assertTaskTitles(
            in: "cancel my gym membership, I'm done paying for it",
            contain: ["gym", "cancel"]
        )
    }

    // MARK: - "finish" / "end" inside a sentence must survive

    func test_finishInsideSentence_finishReport() async throws {
        try await assertTaskTitles(
            in: "finish the quarterly report",
            contain: ["report"]
        )
    }

    func test_finishInsideSentence_finishPainting() async throws {
        try await assertTaskTitles(
            in: "finish painting the bedroom this weekend",
            contain: ["paint"]
        )
    }

    func test_endInsideSentence_endNetflixSubscription() async throws {
        try await assertTaskTitles(
            in: "remind me to end my Netflix subscription before the free trial expires",
            contain: ["Netflix"]
        )
    }

    func test_endInsideSentence_endMeetingEarly() async throws {
        try await assertTaskTitles(
            in: "email John and ask him to end the meeting early on Thursday",
            contain: ["John"]
        )
    }

    // MARK: - Trailing closers must NOT produce tasks

    func test_trailingCloser_callDentistThatSIt() async throws {
        let result = try await parse("call dentist and make appointment that's it")
        // Should produce exactly 1 task about the dentist, nothing about "that's it"
        try await assertNoTaskTitle(in: "call dentist and make appointment that's it", contains: "that's it")
        try await assertNoTaskTitle(in: "call dentist and make appointment that's it", contains: "thats it")
        XCTAssertGreaterThan(result.tasks.count, 0, "Should still produce the dentist task")
    }

    func test_trailingCloser_buyGroceriesOkDone() async throws {
        try await assertNoTaskTitle(in: "buy milk eggs and bread ok done", contains: "ok done")
        try await assertTaskTitles(in: "buy milk eggs and bread ok done", contain: ["milk", "groceries", "bread"])
    }

    func test_trailingCloser_payRentImDone() async throws {
        try await assertNoTaskTitle(in: "pay rent online I'm done", contains: "done")
        try await assertTaskTitles(in: "pay rent online I'm done", contain: ["rent"])
    }

    func test_trailingCloser_callFamilyThatSAll() async throws {
        // 3 tasks: call mom, call dad, call sister — "that's all" is not a task
        let result = try await parse("call mom dad and sister that's all")
        try await assertNoTaskTitle(in: "call mom dad and sister that's all", contains: "that's all")
        XCTAssertGreaterThan(result.tasks.count, 0)
    }

    func test_trailingCloser_exerciseThatSEverything() async throws {
        try await assertNoTaskTitle(
            in: "remind me to exercise tomorrow morning that's everything",
            contains: "everything"
        )
        try await assertTaskTitles(
            in: "remind me to exercise tomorrow morning that's everything",
            contain: ["exercise"]
        )
    }

    func test_trailingCloser_multiTaskOkDone() async throws {
        let transcript = "call dentist, pay electricity bill, and buy groceries ok done"
        let result = try await parse(transcript)
        // Expect 3 tasks, none of which is "ok done"
        XCTAssertEqual(result.tasks.count, 3,
            "Expected 3 tasks, got \(result.tasks.count): \(result.tasks.map(\.title))")
        try await assertNoTaskTitle(in: transcript, contains: "ok done")
    }

    // MARK: - Multi-task transcripts must produce the right count

    func test_multiTask_twoReminders() async throws {
        // The original bug: "create a reminder to X and also create a reminder to Y" → only 1 created
        try await assertTaskCount(
            in: "create a reminder to call Xfinity and also create a reminder to deposit a check",
            expected: 2
        )
    }

    func test_multiTask_numberedList() async throws {
        try await assertTaskCount(
            in: "I need to do three things: one, call the dentist, two, pay rent, three, buy groceries",
            expected: 3
        )
    }

    func test_multiTask_andAlsoConjunction() async throws {
        try await assertTaskCount(
            in: "call mom and also email the accountant",
            expected: 2
        )
    }

    func test_multiTask_stopInsideOneTask() async throws {
        // Two real tasks, one of which contains "stop" — count should be 2
        try await assertTaskCount(
            in: "call AT&T to stop calling me and also cancel the Equinox membership",
            expected: 2
        )
        try await assertTaskTitles(
            in: "call AT&T to stop calling me and also cancel the Equinox membership",
            contain: ["AT&T", "Equinox"]
        )
    }

    // MARK: - Correction rule: "actually / change it to / scratch that" → only the final version

    func test_correction_actuallyXfinity() async throws {
        // The original bug: user corrected AT&T → Xfinity in the same voice note.
        // Should produce exactly 1 task, about Xfinity, not AT&T.
        let transcript = "create a reminder to call AT&T to negotiate, actually change it to call Xfinity instead"
        let result = try await parse(transcript)
        XCTAssertEqual(result.tasks.count, 1,
            "Correction should yield exactly 1 task, got: \(result.tasks.map(\.title))")
        let title = result.tasks.first?.title.lowercased() ?? ""
        XCTAssertTrue(title.contains("xfinity"), "Task should be about Xfinity, got: '\(title)'")
        XCTAssertFalse(title.contains("at&t"), "Corrected task should not mention AT&T, got: '\(title)'")
    }

    func test_correction_scratchThat() async throws {
        let transcript = "buy milk, scratch that, buy almond milk"
        let result = try await parse(transcript)
        XCTAssertEqual(result.tasks.count, 1,
            "Scratch-that correction should yield 1 task, got: \(result.tasks.map(\.title))")
        let title = result.tasks.first?.title.lowercased() ?? ""
        XCTAssertTrue(title.contains("almond"), "Should be almond milk after correction, got: '\(title)'")
    }

    func test_correction_noWait() async throws {
        let transcript = "call John, no wait, email John instead"
        let result = try await parse(transcript)
        XCTAssertEqual(result.tasks.count, 1,
            "No-wait correction should yield 1 task, got: \(result.tasks.map(\.title))")
        let title = result.tasks.first?.title.lowercased() ?? ""
        XCTAssertTrue(title.contains("email") || title.contains("john"),
            "Should be email-related after correction, got: '\(title)'")
        XCTAssertFalse(title.contains("call") && !title.contains("email"),
            "Should not be the pre-correction 'call' task, got: '\(title)'")
    }

    func test_correction_IMeant() async throws {
        let transcript = "add a reminder for Monday, I mean Tuesday"
        let result = try await parse(transcript)
        XCTAssertEqual(result.tasks.count, 1)
    }

    func test_correction_doesNotDropTask_whenNoCorrectionPresent() async throws {
        // Make sure adding the correction rule doesn't cause false positives on
        // transcripts that mention "instead" without being corrections
        let transcript = "buy oat milk instead of regular milk"
        let result = try await parse(transcript)
        XCTAssertGreaterThan(result.tasks.count, 0, "Should still capture the task")
    }

    // MARK: - Commands must not be mis-classified as tasks

    func test_command_showTasks_notATask() async throws {
        let result = try await parse("show me my tasks")
        XCTAssertNotNil(result.command, "Expected a command, got tasks: \(result.tasks.map(\.title))")
        XCTAssertEqual(result.tasks.count, 0)
    }

    func test_command_completeAll_notATask() async throws {
        let result = try await parse("mark all tasks as done")
        XCTAssertNotNil(result.command)
        XCTAssertEqual(result.tasks.count, 0)
    }

    // MARK: - schedule_reminder must require a specific time

    func test_scheduleReminder_requiresTime_noTime_becomesTask() async throws {
        // "Create a reminder to call X" with NO time → should become task_creation, not schedule_reminder
        let result = try await parse("create a reminder to call the plumber")
        // Either a task or a scheduleReminder with empty rawTime (fallback creates task)
        if let command = result.command, case .scheduleReminder(_, let rawTime) = command {
            XCTAssertTrue(rawTime.isEmpty, "scheduleReminder with no time should have empty rawTime so fallback creates a task")
        } else {
            XCTAssertGreaterThan(result.tasks.count, 0, "Should produce a task when no time is given")
        }
    }

    func test_scheduleReminder_withTime_isReminder() async throws {
        let result = try await parse("remind me to call the plumber at 3pm")
        if let command = result.command, case .scheduleReminder(_, let rawTime) = command {
            XCTAssertFalse(rawTime.isEmpty, "scheduleReminder with '3pm' should have a rawTime")
        } else {
            XCTFail("Expected a scheduleReminder command, got tasks: \(result.tasks.map(\.title))")
        }
    }
}
