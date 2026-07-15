import XCTest
@testable import FocusFlow

// MARK: - VoxdumpNavCommandTests
// Pure-logic tests for the always-on Tasks-list command engine: NavCommandMatcher (transcript
// -> command + TaskSelector) and NavCommandResolver (selector -> concrete task indices).
// Many fixtures are the EXACT transcripts captured in device logs on 2026-07-14, where the old
// grammar mis-handled ordinals ("mark the first"), bulk ("complete all"), dates, and
// name-before-verb ("call plumber is done"). No AI, no async, instant.

final class VoxdumpNavCommandTests: XCTestCase {

    private func m(_ text: String) -> NavCommand? { NavCommandMatcher.match(text) }

    // MARK: Nav verbs

    func test_new_task() { XCTAssertEqual(m("new task"), .newDump) }
    func test_new_brainDump() { XCTAssertEqual(m("brain dump"), .newDump) }
    func test_new_addATask() { XCTAssertEqual(m("add a task"), .newDump) }
    func test_new_createNewTask_realLog() { XCTAssertEqual(m("Create a new task"), .newDump) }
    func test_new_addNewTask_realLog() { XCTAssertEqual(m("Add a new task"), .newDump) }
    func test_new_anotherTask() { XCTAssertEqual(m("add another task"), .newDump) }
    func test_read_list() { XCTAssertEqual(m("read my tasks"), .readTasks) }
    func test_mute() { XCTAssertEqual(m("mute"), .mute) }
    func test_mute_stopListening() { XCTAssertEqual(m("stop listening"), .mute) }
    func test_goBack() { XCTAssertEqual(m("go back"), .goBack) }
    func test_goHome() { XCTAssertEqual(m("go home"), .goBack) }

    // MARK: Show / navigate to the list (Home voice navigation)

    func test_showTasks_plain() { XCTAssertEqual(m("show my tasks"), .showTasks(.all)) }
    func test_showTasks_takeMeTo() { XCTAssertEqual(m("take me to tasks"), .showTasks(.all)) }
    func test_showTasks_goToTasks() { XCTAssertEqual(m("go to my tasks"), .showTasks(.all)) }
    func test_showTasks_pending() { XCTAssertEqual(m("show pending"), .showTasks(.pending)) }
    func test_showTasks_pendingTasks() { XCTAssertEqual(m("show my pending tasks"), .showTasks(.pending)) }
    func test_showTasks_completed() { XCTAssertEqual(m("show completed"), .showTasks(.completed)) }
    func test_showTasks_doneTasks() { XCTAssertEqual(m("show done tasks"), .showTasks(.completed)) }
    func test_showTasks_notReadAloud() { XCTAssertEqual(m("read my tasks"), .readTasks) }   // "read" stays readTasks

    // "show all [tasks]" must show the WHOLE list, never open task #1 (bug 1: it opened "submit
    // immigration"). Regression guards keep "complete all"/"clear all" as bulk mutations.
    func test_showAll_tasks() { XCTAssertEqual(m("show all tasks"), .showTasks(.all)) }
    func test_showAll_bare() { XCTAssertEqual(m("show all"), .showTasks(.all)) }
    func test_viewAll_tasks() { XCTAssertEqual(m("view all tasks"), .showTasks(.all)) }
    func test_showEverything() { XCTAssertEqual(m("show everything"), .showTasks(.all)) }
    func test_listAll() { XCTAssertEqual(m("list all tasks"), .showTasks(.all)) }
    func test_showAll_pending() { XCTAssertEqual(m("show all pending tasks"), .showTasks(.pending)) }
    func test_showAll_completed() { XCTAssertEqual(m("show all completed tasks"), .showTasks(.completed)) }
    func test_showAll_notOpen() {   // the exact bug: must NOT be an open command
        if case .open = m("show all tasks") { XCTFail("‘show all tasks’ must not open a task") }
    }
    func test_regression_completeAll_stillBulk() { XCTAssertEqual(m("complete all tasks"), .complete(.all)) }
    func test_regression_clearAll_stillDelete() { XCTAssertEqual(m("clear all"), .delete(.all)) }
    func test_regression_markAll_stillComplete() { XCTAssertEqual(m("mark all as done"), .complete(.all)) }

    // Open/show a SPECIFIC task must resolve to open(name) (the experience to protect from regression).
    func test_open_showNamedTask() { XCTAssertEqual(m("show call immigration"), .open(.name("call immigration"))) }
    func test_open_showSubmitImmigration() { XCTAssertEqual(m("show submit immigration"), .open(.name("submit immigration"))) }
    func test_open_openNamedTask() { XCTAssertEqual(m("open groceries"), .open(.name("groceries"))) }
    func test_open_viewNamedTask() { XCTAssertEqual(m("view the dentist task"), .open(.name("dentist"))) }

    // MARK: Ordinals (bug 3 — "complete 2nd task does nothing")

    func test_complete_first() { XCTAssertEqual(m("mark the first"), .complete(.ordinal(1))) }
    func test_complete_firstTask_realLog() { XCTAssertEqual(m("Mark the first"), .complete(.ordinal(1))) }
    func test_complete_secondTask() { XCTAssertEqual(m("complete the second task"), .complete(.ordinal(2))) }
    func test_complete_2nd() { XCTAssertEqual(m("mark the 2nd task done"), .complete(.ordinal(2))) }
    func test_complete_numberThree() { XCTAssertEqual(m("complete task 3"), .complete(.ordinal(3))) }
    func test_open_first() { XCTAssertEqual(m("Open first"), .open(.ordinal(1))) }
    func test_delete_last() { XCTAssertEqual(m("delete the last one"), .delete(.last)) }
    func test_complete_last() { XCTAssertEqual(m("mark the last task as done"), .complete(.last)) }
    func test_delete_second() { XCTAssertEqual(m("Remove second"), .delete(.ordinal(2))) }

    // MARK: Bulk "all" (bugs 4 & 7 — "complete all" / "clear all" did nothing)

    func test_complete_all() { XCTAssertEqual(m("Complete all"), .complete(.all)) }
    func test_mark_all() { XCTAssertEqual(m("Mark all"), .complete(.all)) }
    func test_complete_allTasks() { XCTAssertEqual(m("complete all tasks"), .complete(.all)) }
    func test_complete_everything() { XCTAssertEqual(m("mark everything as done"), .complete(.all)) }
    func test_delete_all() { XCTAssertEqual(m("Clear all"), .delete(.all)) }
    func test_delete_everything() { XCTAssertEqual(m("delete everything"), .delete(.all)) }
    func test_delete_allTasks() { XCTAssertEqual(m("clear all tasks"), .delete(.all)) }

    // MARK: Date-scoped bulk (bug 3 — "complete all tasks created yesterday")

    func test_complete_createdYesterday() {
        XCTAssertEqual(m("complete all tasks created yesterday"), .complete(.createdOn(.yesterday)))
    }
    func test_delete_fromToday() {
        XCTAssertEqual(m("delete all tasks from today"), .delete(.createdOn(.today)))
    }
    func test_complete_addedYesterday() {
        XCTAssertEqual(m("mark tasks added yesterday as done"), .complete(.createdOn(.yesterday)))
    }

    // MARK: Named (fuzzy hint resolved later by TaskMatcher)

    func test_complete_named() { XCTAssertEqual(m("complete laundry"), .complete(.name("laundry"))) }
    func test_open_named() { XCTAssertEqual(m("open groceries"), .open(.name("groceries"))) }
    func test_delete_named() { XCTAssertEqual(m("delete the meeting notes"), .delete(.name("meeting notes"))) }
    func test_open_named_multiword() { XCTAssertEqual(m("open remove sumit paperwork"), .open(.name("remove sumit paperwork"))) }

    // MARK: Name-before-verb (bug — "call plumber is done" -> no match)

    func test_trailingDone_isDone() { XCTAssertEqual(m("call plumber is done"), .complete(.name("call plumber"))) }
    func test_trailingDone_bare() { XCTAssertEqual(m("call plumber done"), .complete(.name("call plumber"))) }
    func test_trailingDone_finished() { XCTAssertEqual(m("the report is finished"), .complete(.name("report"))) }
    func test_trailingDone_realLog() { XCTAssertEqual(m("Call plumber is done"), .complete(.name("call plumber"))) }

    // MARK: Reopen / reactivate

    func test_reopen_named() { XCTAssertEqual(m("reopen call plumber"), .reopen(.name("call plumber"))) }
    func test_reopen_notDone() {
        // "mark X as not done" reactivates rather than completing.
        if case .reopen = m("mark the dentist as not done") {} else { XCTFail("expected reopen") }
    }

    // MARK: Bare verb never returns a destructive/again-empty command

    func test_bare_delete_nil() { XCTAssertNil(m("delete")) }
    func test_bare_complete_nil() { XCTAssertNil(m("complete")) }
    func test_gibberish_nil() { XCTAssertNil(m("Yesi Tu Asi Ho office Main Hoon Ki")) }

    // MARK: - Resolver

    private let day0 = Date(timeIntervalSince1970: 1_700_000_000)          // fixed "today"
    private var yesterday: Date { day0.addingTimeInterval(-86_400) }

    /// Display order = most-recent first, matching AllTasksView's @Query(reverse createdAt).
    private func snap() -> [TaskSnapshot] {
        [
            .init(title: "Water the plants", isCompleted: false, createdAt: day0),        // 0 pending
            .init(title: "Buy groceries",    isCompleted: false, createdAt: day0),        // 1 pending
            .init(title: "Call mom",         isCompleted: false, createdAt: yesterday),   // 2 pending (yesterday)
            .init(title: "Go for a walk",    isCompleted: true,  createdAt: yesterday),   // 3 completed
            .init(title: "Call plumber",     isCompleted: true,  createdAt: day0)         // 4 completed
        ]
    }
    private func resolve(_ c: NavCommand) -> [Int] {
        NavCommandResolver.resolve(c, in: snap(), now: day0, calendar: .current)
    }

    func test_resolve_completeAll_onlyPending() {
        XCTAssertEqual(resolve(.complete(.all)), [0, 1, 2])   // never the completed 3,4
    }
    func test_resolve_completeFirst_isTopPending() {
        XCTAssertEqual(resolve(.complete(.ordinal(1))), [0])
    }
    func test_resolve_completeSecond() {
        XCTAssertEqual(resolve(.complete(.ordinal(2))), [1])
    }
    func test_resolve_completeLast_pending() {
        XCTAssertEqual(resolve(.complete(.last)), [2])
    }
    func test_resolve_completeOrdinalOutOfRange_empty() {
        XCTAssertEqual(resolve(.complete(.ordinal(9))), [])
    }
    func test_resolve_completeYesterday_pendingOnly() {
        XCTAssertEqual(resolve(.complete(.createdOn(.yesterday))), [2])   // Call mom; not completed 3
    }
    func test_resolve_completeToday() {
        XCTAssertEqual(resolve(.complete(.createdOn(.today))), [0, 1])
    }
    func test_resolve_deleteAll_everything() {
        XCTAssertEqual(resolve(.delete(.all)), [0, 1, 2, 3, 4])   // clear the whole list
    }
    func test_resolve_openName_prefersPending() {
        // Only "Call mom" is pending for "call mom"; open -> index 2, not a completed task.
        XCTAssertEqual(resolve(.open(.name("call mom"))), [2])
    }
    func test_resolve_completeName_pendingOnly_skipsCompleted() {
        // "call plumber" matches the COMPLETED task, but complete only targets pending -> empty.
        XCTAssertEqual(resolve(.complete(.name("call plumber"))), [])
    }
    func test_resolve_reopenName_completedOnly() {
        XCTAssertEqual(resolve(.reopen(.name("call plumber"))), [4])
    }
    func test_resolve_openName_fallsBackToCompleted() {
        // No pending match for "walk"; open falls back to any task (the completed one).
        XCTAssertEqual(resolve(.open(.name("walk"))), [3])
    }

    // MARK: isBulk (caller confirmation gating)

    func test_isBulk_all() { XCTAssertTrue(NavCommandResolver.isBulk(.delete(.all))) }
    func test_isBulk_date() { XCTAssertTrue(NavCommandResolver.isBulk(.complete(.createdOn(.today)))) }
    func test_isBulk_single_false() { XCTAssertFalse(NavCommandResolver.isBulk(.complete(.ordinal(1)))) }

    // MARK: Home routing (bug 3 — a named "open/show <task>" on Home opens THAT task, not the list)
    // HomeVoiceRouter is the pure decision behind HomeView.evaluate. Before the fix, .open always
    // routed to .showTasks(.all) ("can't reliably resolve one task from Home"). These assert Home
    // now resolves the named task against its own list — a resolver-only test would pass even with
    // the bug present, because the resolver was never the problem; Home ignoring it was.

    private func home(_ text: String, _ titles: [String]) -> HomeVoiceOutcome {
        // Display order = most-recent first; give descending createdAt so index order is stable.
        let snap = titles.enumerated().map { i, t in
            TaskSnapshot(title: t, isCompleted: false, createdAt: Date(timeIntervalSince1970: TimeInterval(10_000 - i)))
        }
        return HomeVoiceRouter.outcome(for: text, tasks: snap)
    }

    func test_home_openNamedTask_opensThatTask() {
        XCTAssertEqual(home("show call immigration", ["buy groceries", "call immigration", "pay rent"]), .openTask(1))
    }
    func test_home_openByName_fuzzy() {
        XCTAssertEqual(home("open groceries", ["buy groceries", "call mom"]), .openTask(0))
    }
    func test_home_openUnresolvedName_fallsBackToList() {
        // A name we can't confidently match falls back to the full list — never a wrong task.
        XCTAssertEqual(home("show quantum physics", ["buy groceries", "call mom"]), .showTasks(.all))
    }
    func test_home_openWithNoTasks_fallsBackToList() {
        XCTAssertEqual(home("show call mom", []), .showTasks(.all))
    }
    func test_home_openFirstOrdinal_opensMostRecent() {
        XCTAssertEqual(home("open first", ["newest", "older"]), .openTask(0))
    }
    func test_home_showAll_staysList_notOpen() {   // bug 1 must still hold on Home
        XCTAssertEqual(home("show all tasks", ["a", "b"]), .showTasks(.all))
    }
    func test_home_showPending_navigates() {
        XCTAssertEqual(home("show pending", ["a"]), .showTasks(.pending))
    }
    func test_home_newTask_opensCapture() {
        XCTAssertEqual(home("new task", []), .newDump)
    }
    func test_home_mute() { XCTAssertEqual(home("mute", ["a"]), .mute) }
    func test_home_readTasks() { XCTAssertEqual(home("read my tasks", ["a"]), .readTasks) }
    func test_home_completeIsIgnoredOnHome() {   // complete/delete/reopen aren't meaningful on Home
        XCTAssertEqual(home("complete first", ["a", "b"]), .ignore)
    }
    func test_home_nonCommandPhrase_isCaptured() {
        XCTAssertEqual(home("remind me to call the debt collector", []), .capture("remind me to call the debt collector"))
    }
    func test_home_oneWordNoise_isIgnored() {
        XCTAssertEqual(home("uh", []), .ignore)
    }

    // MARK: Robust nav phrasings (device-log flakiness: go-to-filter, show-the-tasks, close)
    // These are the EXACT phrasings that misfired on device: "go to pending" opened a task named
    // "pending", "go to done" completed a task named "go", "show the tasks" / "close tasks" no-matched.

    func test_nav_goToPending()      { XCTAssertEqual(m("go to pending"), .showTasks(.pending)) }
    func test_nav_goToDone()         { XCTAssertEqual(m("go to done"), .showTasks(.completed)) }
    func test_nav_goToCompleted()    { XCTAssertEqual(m("go to completed"), .showTasks(.completed)) }
    func test_nav_seePending()       { XCTAssertEqual(m("see pending"), .showTasks(.pending)) }
    func test_nav_seeDone()          { XCTAssertEqual(m("see done"), .showTasks(.completed)) }
    func test_nav_showThe_tasks()    { XCTAssertEqual(m("show the tasks"), .showTasks(.all)) }
    func test_nav_show_bare()        { XCTAssertEqual(m("show"), .showTasks(.all)) }
    // "open my tasks" reads "open" as the pending/unfinished filter (pre-existing: "open tasks" ==
    // unfinished tasks); still a list navigation, which is the point here.
    func test_nav_openMyTasks()      { XCTAssertEqual(m("open my tasks"), .showTasks(.pending)) }
    func test_nav_viewTasks()        { XCTAssertEqual(m("view tasks"), .showTasks(.all)) }

    // "close" = dismiss the current screen (the visible X), never "complete a task".
    func test_close_bare()           { XCTAssertEqual(m("close"), .goBack) }
    func test_close_tasks()          { XCTAssertEqual(m("close tasks"), .goBack) }
    func test_close_taskPage()       { XCTAssertEqual(m("close task page"), .goBack) }
    func test_close_thisPage()       { XCTAssertEqual(m("close this page"), .goBack) }
    func test_close_nonLeading_isNotGoBack() {
        // "close" mid-phrase is part of a task name after a real verb, not a dismiss.
        guard case .complete = m("complete close the deal") else {
            return XCTFail("leading verb 'complete' should win over a non-leading 'close'")
        }
    }

    // Regression guards: a NAMED open/show must still open that task, "show all" still lists.
    func test_nav_openNamed_stillOpens() { XCTAssertEqual(m("open groceries"), .open(.name("groceries"))) }
    func test_nav_showNamed_stillOpens() { XCTAssertEqual(m("show call immigration"), .open(.name("call immigration"))) }
    func test_nav_showAll_stillList()    { XCTAssertEqual(m("show all tasks"), .showTasks(.all)) }
}
