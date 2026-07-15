import XCTest
@testable import FocusFlow

// Tests for FocusCommandMatcher — the voice vocabulary on the single-task detail screen
// (TaskFocusView). Covers exactly the interactions that regressed / were reported missing:
// task-to-task navigation, marking a specific STEP complete by ordinal, whole-task completion,
// and returning to the list. Pure, instant, no SwiftUI.
final class VoxdumpFocusCommandTests: XCTestCase {

    private func m(_ t: String) -> FocusCommand? { FocusCommandMatcher.match(t) }

    // MARK: Task-to-task navigation
    func test_next()          { XCTAssertEqual(m("next"), .next) }
    func test_next_task()     { XCTAssertEqual(m("next task"), .next) }
    func test_show_next()     { XCTAssertEqual(m("show next"), .next) }        // the user's phrasing
    func test_forward()       { XCTAssertEqual(m("go forward"), .next) }
    func test_previous()      { XCTAssertEqual(m("previous"), .previous) }
    func test_previous_task() { XCTAssertEqual(m("previous task"), .previous) }
    func test_prev()          { XCTAssertEqual(m("prev"), .previous) }

    // MARK: Return to the list (must NOT be read as "previous")
    func test_goBack_bare()   { XCTAssertEqual(m("back"), .goBack) }
    func test_goBack_go()     { XCTAssertEqual(m("go back"), .goBack) }
    func test_goBack_toTasks(){ XCTAssertEqual(m("go to tasks"), .goBack) }
    func test_goBack_close()  { XCTAssertEqual(m("close"), .goBack) }

    // MARK: Complete a STEP by ordinal (the reported "mark first/second/third step complete")
    func test_step_completeFirst()  { XCTAssertEqual(m("complete first step"), .completeStep(1)) }
    func test_step_markFirst()      { XCTAssertEqual(m("mark the first step complete"), .completeStep(1)) }
    func test_step_second()         { XCTAssertEqual(m("mark second step complete"), .completeStep(2)) }
    func test_step_third()          { XCTAssertEqual(m("complete the third step"), .completeStep(3)) }
    func test_step_checkOffNumber() { XCTAssertEqual(m("check off step 2"), .completeStep(2)) }
    func test_step_doneSuffix()     { XCTAssertEqual(m("first step done"), .completeStep(1)) }
    func test_step_bareStepNumber() { XCTAssertEqual(m("step three"), .completeStep(3)) }
    func test_step_last()           { XCTAssertEqual(m("complete the last step"), .completeStep(Int.max)) }

    // MARK: Whole-task completion (no ordinal)
    func test_task_complete()       { XCTAssertEqual(m("complete task"), .completeTask) }
    func test_task_markTask()       { XCTAssertEqual(m("mark task complete"), .completeTask) }
    func test_task_markComplete()   { XCTAssertEqual(m("mark complete"), .completeTask) }
    func test_task_allDone()        { XCTAssertEqual(m("all done"), .completeTask) }
    func test_task_bareDone()       { XCTAssertEqual(m("done"), .completeTask) }

    // MARK: Non-commands
    func test_noise_ignored()   { XCTAssertNil(m("um what was i doing")) }
    func test_random_ignored()  { XCTAssertNil(m("the weather is nice today")) }
}
