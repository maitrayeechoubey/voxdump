import XCTest
@testable import FocusFlow

// MARK: - VoxdumpDestructiveGuardTests
// Pure-logic tests for the deterministic destructive-safety guards in AIParsingManager
// (guardedIntent + mentionsEntireList). No AI, no async, instant.
//
// These guard the 2026-07-13 data-loss regression: "remove nicobar island tasks" deleted a
// dozen unrelated tasks because a named delete escalated to delete_all. The invariant under
// test: a delete that names a specific subject can NEVER resolve to delete_all.

final class VoxdumpDestructiveGuardTests: XCTestCase {

    private func guarded(_ intent: String, _ transcript: String) -> String {
        AIParsingManager.guardedIntent(intent, transcript: transcript)
    }

    // MARK: The exact regression — a named/specific delete must never become delete_all.

    func test_regression_removeNamedTasks_neverDeleteAll() {
        XCTAssertNotEqual(guarded("delete_all", "remove nicobar island tasks"), "delete_all")
        XCTAssertEqual(guarded("delete_all", "remove nicobar island tasks"), "delete_named")
    }
    func test_namedDelete_staysNamed() {
        XCTAssertEqual(guarded("delete_named", "remove nicobar island tasks"), "delete_named")
        XCTAssertEqual(guarded("delete_named", "delete the gym task"), "delete_named")
    }
    func test_specificDelete_withWordContainingAll_notDeleteAll() {
        // "install" contains the substring "all" but is not the word "all".
        XCTAssertEqual(guarded("delete_all", "delete the install task"), "delete_named")
    }

    // MARK: Legitimate whole-list deletes must still work.

    func test_deleteAll_plain() { XCTAssertEqual(guarded("delete_all", "delete all"), "delete_all") }
    func test_deleteAll_allTasks() { XCTAssertEqual(guarded("delete_all", "clear all tasks"), "delete_all") }
    func test_deleteAll_everything() { XCTAssertEqual(guarded("delete_all", "clear everything"), "delete_all") }
    func test_deleteAll_myTasks() { XCTAssertEqual(guarded("delete_all", "clear my tasks"), "delete_all") }
    func test_deleteAll_wipeMyList() { XCTAssertEqual(guarded("delete_all", "wipe my list"), "delete_all") }
    func test_deleteAll_startFresh() { XCTAssertEqual(guarded("delete_all", "start fresh"), "delete_all") }

    // MARK: Destructive-clear guard (leading delete verb corrects a misread completion).

    func test_clearAll_fromCompleteAll_becomesDeleteAll() {
        XCTAssertEqual(guarded("complete_all", "clear all the tasks"), "delete_all")
    }
    func test_clearDone_scopesToCompleted() {
        XCTAssertEqual(guarded("complete_all", "clear all the done tasks"), "delete_completed")
        XCTAssertEqual(guarded("delete_all", "clear the completed tasks"), "delete_completed")
    }
    func test_clearNamed_fromCompleteNamed_becomesDeleteNamed() {
        XCTAssertEqual(guarded("complete_named", "delete the gym task"), "delete_named")
    }

    // MARK: Negation guard (reopen, not complete).

    func test_negation_named() { XCTAssertEqual(guarded("complete_named", "mark the dentist task as not done"), "reactivate_named") }
    func test_negation_all() { XCTAssertEqual(guarded("complete_all", "mark all tasks as not done"), "reactivate_all") }

    // MARK: Non-destructive intents pass through untouched.

    func test_taskCreation_untouched() { XCTAssertEqual(guarded("task_creation", "call nicobar island"), "task_creation") }
    func test_showTasks_untouched() { XCTAssertEqual(guarded("show_tasks", "show me my list"), "show_tasks") }
    func test_completeNamed_untouched() { XCTAssertEqual(guarded("complete_named", "mark rent as done"), "complete_named") }

    // MARK: mentionsEntireList — whole-word so common words never read as "all".

    func test_entireList_true_all() { XCTAssertTrue(AIParsingManager.mentionsEntireList("delete all")) }
    func test_entireList_true_everything() { XCTAssertTrue(AIParsingManager.mentionsEntireList("wipe everything")) }
    func test_entireList_true_myTasks() { XCTAssertTrue(AIParsingManager.mentionsEntireList("clear my tasks")) }
    func test_entireList_false_call() { XCTAssertFalse(AIParsingManager.mentionsEntireList("call nicobar island")) }   // "call" != "all"
    func test_entireList_false_install() { XCTAssertFalse(AIParsingManager.mentionsEntireList("delete the install task")) }
    func test_entireList_false_named() { XCTAssertFalse(AIParsingManager.mentionsEntireList("remove nicobar island tasks")) }
    func test_entireList_false_singleTask() { XCTAssertFalse(AIParsingManager.mentionsEntireList("delete the gym task")) }

    // MARK: Name-collision false positives (adversarial-review Hole 1). A task NAME that embeds
    // "all"/"the list"/"my tasks" must NOT read as whole-list — else a misclassified delete_all
    // would wipe everything. These are the exact inputs the reviewer used to break the first fix.

    func test_namedDelete_allHands_notEntireList() {
        XCTAssertFalse(AIParsingManager.mentionsEntireList("delete the all hands meeting task"))
        XCTAssertEqual(guarded("delete_all", "delete the all hands meeting task"), "delete_named")
    }
    func test_namedDelete_theListInName_notEntireList() {
        XCTAssertFalse(AIParsingManager.mentionsEntireList("delete the update the list task"))
        XCTAssertEqual(guarded("delete_all", "delete the update the list task"), "delete_named")
    }
    func test_namedDelete_allStar_notEntireList() {
        XCTAssertEqual(guarded("delete_all", "remove the all star task"), "delete_named")
    }
    func test_namedDelete_myTasksInName_notEntireList() {
        XCTAssertEqual(guarded("delete_all", "clear the my tasks dashboard task"), "delete_named")
    }
    func test_scopedAllTasks_notEntireList() {
        // "all <subject> tasks" is a scoped delete, not the whole list.
        XCTAssertFalse(AIParsingManager.mentionsEntireList("delete all nicobar tasks"))
    }
    // "delete every X" / "delete everything X" are scoped or named, never whole-list (Hole 2).
    func test_scopedEvery_notEntireList() {
        XCTAssertFalse(AIParsingManager.mentionsEntireList("delete every overdue task"))
        XCTAssertEqual(guarded("delete_all", "delete every overdue task"), "delete_named")
    }
    func test_namedEverythingBagel_notEntireList() {
        XCTAssertFalse(AIParsingManager.mentionsEntireList("delete everything bagel"))
        XCTAssertEqual(guarded("delete_all", "delete everything bagel"), "delete_named")
    }
    func test_scopedRemoveEvery_notEntireList() {
        XCTAssertFalse(AIParsingManager.mentionsEntireList("remove every duplicate"))
    }
    // ...but the exact whole-list quantifiers still resolve to delete_all:
    func test_entireList_true_everythingExact() { XCTAssertTrue(AIParsingManager.mentionsEntireList("clear everything")) }
    func test_entireList_true_everyTaskExact() { XCTAssertTrue(AIParsingManager.mentionsEntireList("delete every task")) }

    // MARK: Hole-2 fixes — common whole-list phrasings that must resolve to delete_all.

    func test_entireList_true_deleteThem() { XCTAssertTrue(AIParsingManager.mentionsEntireList("delete them")) }
    func test_entireList_true_getRidOfThem() { XCTAssertTrue(AIParsingManager.mentionsEntireList("get rid of them")) }
    func test_entireList_true_startFromScratch() { XCTAssertTrue(AIParsingManager.mentionsEntireList("start from scratch")) }
    func test_entireList_true_reset() { XCTAssertTrue(AIParsingManager.mentionsEntireList("reset")) }
    func test_entireList_true_wholeList() { XCTAssertTrue(AIParsingManager.mentionsEntireList("delete the whole list")) }
    func test_entireList_true_deleteAllOfThem() { XCTAssertTrue(AIParsingManager.mentionsEntireList("delete all of them")) }

    // MARK: Voice confirmation for bulk delete (BulkDeleteConfirmMatcher). Cancel-biased; a clear
    // "yes" confirms, anything ambiguous or cancel-ish does not delete.

    func test_confirm_yes() { XCTAssertEqual(BulkDeleteConfirmMatcher.match("yes"), .confirm) }
    func test_confirm_yeahDoIt() { XCTAssertEqual(BulkDeleteConfirmMatcher.match("yeah do it"), .confirm) }
    func test_confirm_confirm() { XCTAssertEqual(BulkDeleteConfirmMatcher.match("confirm"), .confirm) }
    func test_confirm_deleteThemAll() { XCTAssertEqual(BulkDeleteConfirmMatcher.match("delete them all"), .confirm) }
    func test_confirm_goAhead() { XCTAssertEqual(BulkDeleteConfirmMatcher.match("go ahead"), .confirm) }
    func test_cancel_no() { XCTAssertEqual(BulkDeleteConfirmMatcher.match("no"), .cancel) }
    func test_cancel_cancel() { XCTAssertEqual(BulkDeleteConfirmMatcher.match("cancel"), .cancel) }
    func test_cancel_stop() { XCTAssertEqual(BulkDeleteConfirmMatcher.match("stop"), .cancel) }
    func test_cancel_keepThem() { XCTAssertEqual(BulkDeleteConfirmMatcher.match("keep them"), .cancel) }
    func test_cancel_neverMind() { XCTAssertEqual(BulkDeleteConfirmMatcher.match("never mind"), .cancel) }
    func test_confirm_unclear_nil() { XCTAssertNil(BulkDeleteConfirmMatcher.match("hmm maybe")) }
    func test_confirm_empty_nil() { XCTAssertNil(BulkDeleteConfirmMatcher.match("")) }
    // Ambiguity resolves toward cancel (safe); whole-word so "now" != "no".
    func test_confirm_ambiguous_biasesCancel() { XCTAssertEqual(BulkDeleteConfirmMatcher.match("no actually yes"), .cancel) }
    func test_confirm_deleteNow_notCancel() { XCTAssertEqual(BulkDeleteConfirmMatcher.match("delete them now"), .confirm) }
}
