import XCTest
@testable import FocusFlow

// MARK: - VoxdumpReviewCommandTests
// Pure-logic tests for the hands-free review-card / edit-sheet command matcher
// (ReviewCommandMatcher). No AI, no async, instant. This is the layer that broke on
// 2026-07-13 (spoken "accept" never advanced the card because it was misrecognized as
// "except" and matching was untested), so these cases guard that regression and the
// whole-word / context-switch rules.

final class VoxdumpReviewCommandTests: XCTestCase {

    private func m(_ text: String, editing: Bool = false) -> ReviewCommand? {
        ReviewCommandMatcher.match(text, editing: editing)
    }

    // MARK: Accept

    func test_accept_plain() { XCTAssertEqual(m("accept"), .accept) }
    func test_accept_capitalized() { XCTAssertEqual(m("Accept"), .accept) }
    func test_accept_upper() { XCTAssertEqual(m("ACCEPT"), .accept) }
    // The actual device regression: the recognizer heard "except" for "accept".
    func test_accept_misrecognized_except() { XCTAssertEqual(m("except"), .accept) }
    func test_accept_keep() { XCTAssertEqual(m("keep"), .accept) }
    func test_accept_keepIt() { XCTAssertEqual(m("keep it"), .accept) }
    func test_accept_yes() { XCTAssertEqual(m("yes"), .accept) }
    func test_accept_yeah() { XCTAssertEqual(m("yeah"), .accept) }
    func test_accept_yep() { XCTAssertEqual(m("yep"), .accept) }
    func test_accept_ok() { XCTAssertEqual(m("ok"), .accept) }
    func test_accept_okay() { XCTAssertEqual(m("okay"), .accept) }
    func test_accept_sure() { XCTAssertEqual(m("sure"), .accept) }
    func test_accept_add() { XCTAssertEqual(m("add"), .accept) }
    func test_accept_addIt() { XCTAssertEqual(m("add it"), .accept) }
    func test_accept_soundsGood() { XCTAssertEqual(m("sounds good"), .accept) }
    func test_accept_confirm() { XCTAssertEqual(m("confirm"), .accept) }
    func test_accept_save() { XCTAssertEqual(m("save"), .accept) }
    // Leading/trailing noise and punctuation should not block the keyword.
    func test_accept_withFiller() { XCTAssertEqual(m("uh yes please"), .accept) }
    func test_accept_trailingPunctuation() { XCTAssertEqual(m("accept."), .accept) }

    // MARK: Decline

    func test_decline_plain() { XCTAssertEqual(m("decline"), .decline) }
    func test_decline_skip() { XCTAssertEqual(m("skip"), .decline) }
    func test_decline_skipIt() { XCTAssertEqual(m("skip it"), .decline) }
    func test_decline_no() { XCTAssertEqual(m("no"), .decline) }
    func test_decline_nope() { XCTAssertEqual(m("nope"), .decline) }
    func test_decline_noThanks() { XCTAssertEqual(m("no thanks"), .decline) }
    func test_decline_delete() { XCTAssertEqual(m("delete"), .decline) }
    func test_decline_remove() { XCTAssertEqual(m("remove"), .decline) }
    func test_decline_trash() { XCTAssertEqual(m("trash"), .decline) }
    func test_decline_pass() { XCTAssertEqual(m("pass"), .decline) }
    func test_decline_reject() { XCTAssertEqual(m("reject"), .decline) }

    // MARK: Edit

    func test_edit_plain() { XCTAssertEqual(m("edit"), .edit) }
    func test_edit_changeIt() { XCTAssertEqual(m("change it"), .edit) }
    func test_edit_change() { XCTAssertEqual(m("change"), .edit) }
    func test_edit_modify() { XCTAssertEqual(m("modify"), .edit) }
    func test_edit_rename() { XCTAssertEqual(m("rename"), .edit) }
    func test_edit_fix() { XCTAssertEqual(m("fix"), .edit) }

    // MARK: Done

    func test_done_plain() { XCTAssertEqual(m("done"), .done) }
    func test_done_finished() { XCTAssertEqual(m("finished"), .done) }
    func test_done_thatsAll() { XCTAssertEqual(m("that's all"), .done) }
    func test_done_thatsAll_noApostrophe() { XCTAssertEqual(m("thats all"), .done) }
    func test_done_imDone() { XCTAssertEqual(m("i'm done"), .done) }
    func test_done_stop() { XCTAssertEqual(m("stop"), .done) }
    func test_done_allDone() { XCTAssertEqual(m("all done"), .done) }

    // MARK: Whole-word safety — these must NOT be mistaken for commands.
    // (The old substring match would have wrongly fired on several of these.)

    func test_noFalsePositive_broke_notAccept() { XCTAssertNil(m("i broke it")) }        // "ok" in "broke"
    func test_noFalsePositive_yesterday_notAccept() { XCTAssertNil(m("yesterday")) }      // "yes" in "yesterday"
    func test_noFalsePositive_smoke_notAccept() { XCTAssertNil(m("smoke")) }              // "ok" in "smoke"
    func test_noFalsePositive_knowing_notDecline() { XCTAssertNil(m("knowing")) }         // "no" in "knowing"
    func test_noFalsePositive_now_notDecline() { XCTAssertNil(m("now")) }                 // "no" in "now"
    func test_noFalsePositive_note_notDecline() { XCTAssertNil(m("note")) }               // "no" in "note"
    func test_noFalsePositive_addition_notAccept() { XCTAssertNil(m("addition")) }        // "add" in "addition"
    func test_noFalsePositive_random_notCommand() { XCTAssertNil(m("call the dentist")) }
    func test_noMatch_empty() { XCTAssertNil(m("")) }
    func test_noMatch_whitespace() { XCTAssertNil(m("   ")) }

    // MARK: Editing context — the edit sheet swaps the vocabulary.

    func test_editing_save() { XCTAssertEqual(m("save", editing: true), .save) }
    func test_editing_saveIt() { XCTAssertEqual(m("save it", editing: true), .save) }
    func test_editing_done() { XCTAssertEqual(m("done", editing: true), .save) }
    func test_editing_ok() { XCTAssertEqual(m("ok", editing: true), .save) }
    func test_editing_cancel() { XCTAssertEqual(m("cancel", editing: true), .cancel) }
    func test_editing_discard() { XCTAssertEqual(m("discard", editing: true), .cancel) }
    func test_editing_nevermind() { XCTAssertEqual(m("never mind", editing: true), .cancel) }
    func test_editing_back() { XCTAssertEqual(m("back", editing: true), .cancel) }
    // Review-only words must not fire behind the edit sheet.
    func test_editing_accept_doesNotFireAccept() {
        XCTAssertNotEqual(m("accept", editing: true), .accept)
    }
    func test_editing_skip_isNil() { XCTAssertNil(m("skip", editing: true)) }
    func test_editing_random_isNil() { XCTAssertNil(m("the quarterly report", editing: true)) }

    // MARK: Priority — accept is checked before decline/edit/done.

    func test_priority_yesBeatsNo() { XCTAssertEqual(m("no wait yes"), .accept) }
    func test_priority_acceptBeatsEdit() { XCTAssertEqual(m("accept and edit"), .accept) }

    // MARK: Partial-transcript arrival — single words as the recognizer streams them.

    func test_partial_singleWord_accept() { XCTAssertEqual(m("accept"), .accept) }
    func test_partial_growing_okThenOkay() {
        XCTAssertEqual(m("o"), nil)          // not a command yet
        XCTAssertEqual(m("ok"), .accept)     // fires as soon as the word lands
    }
}
