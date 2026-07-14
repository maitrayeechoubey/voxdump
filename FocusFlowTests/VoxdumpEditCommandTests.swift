import XCTest
@testable import FocusFlow

// MARK: - VoxdumpEditCommandTests
// Pure-logic tests for the edit-sheet conversational command matcher (EditCommandMatcher).
// Guards that structured commands (title/add/remove/clear) win over the short save/cancel
// words, and that step targeting (number / ordinal / last) resolves correctly.

final class VoxdumpEditCommandTests: XCTestCase {

    private func m(_ text: String) -> EditCommand? { EditCommandMatcher.match(text) }

    // MARK: Set title

    func test_title_change() { XCTAssertEqual(m("change the title to buy groceries"), .setTitle("Buy groceries")) }
    func test_title_correct() { XCTAssertEqual(m("correct the title to hello world"), .setTitle("Hello world")) }
    func test_title_set() { XCTAssertEqual(m("set the title to water the plants"), .setTitle("Water the plants")) }
    func test_title_renameTo() { XCTAssertEqual(m("rename to call the bank"), .setTitle("Call the bank")) }
    func test_title_callIt() { XCTAssertEqual(m("call it groceries"), .setTitle("Groceries")) }
    func test_title_trailingFiller() { XCTAssertEqual(m("change the title to buy milk please"), .setTitle("Buy milk")) }
    // Structured title command must beat the bare "save" word inside the new title.
    func test_title_containingSave() { XCTAssertEqual(m("change the title to save the report"), .setTitle("Save the report")) }

    // MARK: Add step

    func test_add_step() { XCTAssertEqual(m("add a step call the bank"), .addStep("Call the bank")) }
    func test_add_stepTo() { XCTAssertEqual(m("add a step to water the plants"), .addStep("Water the plants")) }
    func test_add_newStep() { XCTAssertEqual(m("new step buy milk"), .addStep("Buy milk")) }

    // MARK: Remove step

    func test_remove_byNumber() { XCTAssertEqual(m("remove step 2"), .removeStep(2)) }
    func test_remove_firstOrdinal() { XCTAssertEqual(m("remove the first micro step"), .removeStep(1)) }
    func test_remove_secondOrdinal() { XCTAssertEqual(m("delete the second step"), .removeStep(2)) }
    func test_remove_last() { XCTAssertEqual(m("remove the last step"), .removeLastStep) }
    func test_remove_clearAll() { XCTAssertEqual(m("remove all the steps"), .clearSteps) }
    // "remove the step" with no target is ambiguous -> keep listening (never a wrong removal).
    func test_remove_ambiguous_isNil() { XCTAssertNil(m("remove the step")) }

    // MARK: Save / cancel

    func test_save_plain() { XCTAssertEqual(m("save"), .save) }
    func test_save_done() { XCTAssertEqual(m("done"), .save) }
    func test_save_looksGood() { XCTAssertEqual(m("looks good"), .save) }
    func test_cancel_plain() { XCTAssertEqual(m("cancel"), .cancel) }
    func test_cancel_neverMind() { XCTAssertEqual(m("never mind"), .cancel) }

    // MARK: Nothing

    func test_empty_isNil() { XCTAssertNil(m("")) }
    func test_chatter_isNil() { XCTAssertNil(m("hmm let me think about this")) }
}
