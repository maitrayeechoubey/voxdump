import XCTest
@testable import FocusFlow

// MARK: - VoxdumpNavCommandTests
// Pure-logic tests for the always-on Tasks-list command matcher (NavCommandMatcher).
// No AI, no async, instant. Guards the command routing and, critically, that a bare
// destructive verb with no task name never returns a delete command (the caller still
// confirms deletes on top of this).

final class VoxdumpNavCommandTests: XCTestCase {

    private func m(_ text: String) -> NavCommand? { NavCommandMatcher.match(text) }

    // MARK: Open

    func test_open_plain() { XCTAssertEqual(m("open groceries"), .open("groceries")) }
    func test_open_view() { XCTAssertEqual(m("view the report"), .open("report")) }
    func test_open_goTo_stripsGlue() { XCTAssertEqual(m("go to the dentist task"), .open("dentist")) }
    func test_open_show_stripsMe() { XCTAssertEqual(m("show me the invoices"), .open("invoices")) }

    // MARK: Complete

    func test_complete_plain() { XCTAssertEqual(m("complete laundry"), .complete("laundry")) }
    func test_complete_finish() { XCTAssertEqual(m("finish the report"), .complete("report")) }
    func test_complete_checkOff() { XCTAssertEqual(m("check off milk"), .complete("milk")) }
    func test_complete_done() { XCTAssertEqual(m("done with the dishes"), .complete("dishes")) }

    // MARK: Delete (matcher only extracts; caller confirms)

    func test_delete_plain() { XCTAssertEqual(m("delete groceries"), .delete("groceries")) }
    func test_delete_remove_stripsGlue() { XCTAssertEqual(m("remove the old report"), .delete("old report")) }
    func test_delete_trash() { XCTAssertEqual(m("trash the meeting notes"), .delete("meeting notes")) }

    // MARK: New dump

    func test_new_task() { XCTAssertEqual(m("new task"), .newDump) }
    func test_new_brainDump() { XCTAssertEqual(m("brain dump"), .newDump) }
    func test_new_capture() { XCTAssertEqual(m("capture something"), .newDump) }
    func test_new_addATask() { XCTAssertEqual(m("add a task"), .newDump) }

    // MARK: Read

    func test_read_myTasks() { XCTAssertEqual(m("read my tasks"), .readTasks) }
    func test_read_them() { XCTAssertEqual(m("read them to me"), .readTasks) }
    func test_read_whatDoIHave() { XCTAssertEqual(m("what do i have"), .readTasks) }

    // MARK: Go back / home

    func test_back_goHome() { XCTAssertEqual(m("go home"), .goBack) }
    func test_back_goBack() { XCTAssertEqual(m("go back"), .goBack) }
    func test_back_bare() { XCTAssertEqual(m("back"), .goBack) }
    func test_back_close() { XCTAssertEqual(m("close"), .goBack) }
    // "go home" must win over the open("...") verb "go".
    func test_back_notMisreadAsOpen() { XCTAssertNotEqual(m("go home"), .open("home")) }

    // MARK: Mute

    func test_mute_plain() { XCTAssertEqual(m("mute"), .mute) }
    func test_mute_stopListening() { XCTAssertEqual(m("stop listening"), .mute) }

    // MARK: Safety — a bare verb with no task name is never a command

    func test_safety_bareDelete_isNil() { XCTAssertNil(m("delete")) }
    func test_safety_bareRemove_isNil() { XCTAssertNil(m("remove the task")) }   // only glue after verb
    func test_safety_bareOpen_isNil() { XCTAssertNil(m("open")) }
    func test_safety_bareComplete_isNil() { XCTAssertNil(m("complete the task")) }
    func test_safety_empty_isNil() { XCTAssertNil(m("")) }
    func test_safety_chatter_isNil() { XCTAssertNil(m("the weather is nice outside")) }

    // MARK: Ordering — mute/back checked before task verbs

    func test_order_muteBeatsVerbs() { XCTAssertEqual(m("mute"), .mute) }
    func test_order_partialOpenNoName_isNil() { XCTAssertNil(m("open the")) }
}
