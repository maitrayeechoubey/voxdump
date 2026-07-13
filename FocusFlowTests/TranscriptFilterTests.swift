import XCTest
@testable import FocusFlow

/// Tests for TranscriptFilter.isStopOnly — the gate that decides whether a transcript
/// is "user said they're done talking" vs. real content containing stop-adjacent words.
///
/// Design principle: we must NEVER accidentally swallow a real task because it contains
/// words like "stop", "done", "finish", "end", "ok", or "all done" inside the sentence.
/// False negatives (stop phrase slips through as a task) are annoying.
/// False positives (real task gets silently discarded) are a broken product.
final class TranscriptFilterTests: XCTestCase {

    // MARK: - True positives: these SHOULD be recognized as stop signals

    func test_exactPhrases_thatSIt() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's it"))
    }

    func test_exactPhrases_thatsIt_noApostrophe() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("thats it"))
    }

    func test_exactPhrases_thatSAll() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's all"))
    }

    func test_exactPhrases_thatSAllForNow() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's all for now"))
    }

    func test_exactPhrases_thatSEverything() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's everything"))
    }

    func test_exactPhrases_imDone() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("i'm done"))
    }

    func test_exactPhrases_imDone_noApostrophe() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("im done"))
    }

    func test_exactPhrases_okDone() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("ok done"))
    }

    func test_exactPhrases_okayDone() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("okay done"))
    }

    func test_exactPhrases_allDone() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("all done"))
    }

    func test_exactPhrases_stopRecording() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("stop recording"))
    }

    func test_exactPhrases_endRecording() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("end recording"))
    }

    func test_exactPhrases_finishRecording() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("finish recording"))
    }

    func test_exactPhrases_thatllDo() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that'll do"))
    }

    // MARK: - Whitespace and punctuation tolerance

    func test_whitespace_leadingTrailing() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("  that's it  "))
    }

    func test_punctuation_trailingPeriod() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's it."))
    }

    func test_punctuation_trailingExclamation() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("that's it!"))
    }

    func test_caseInsensitive_mixedCase() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("That's It"))
    }

    func test_caseInsensitive_allCaps() {
        XCTAssertTrue(TranscriptFilter.isStopOnly("THAT'S IT"))
    }

    // MARK: - False positives: these must NOT be swallowed as stop signals
    // Each test documents WHY the word appears inside a real task.

    func test_stopInsideSentence_attStopCalling() {
        // "stop" is the desired outcome for the AT&T call, not a recording command
        XCTAssertFalse(TranscriptFilter.isStopOnly("remind me to call AT&T to stop calling me"))
    }

    func test_stopInsideSentence_stopSmoking() {
        // "stop" is the action the user wants to take
        XCTAssertFalse(TranscriptFilter.isStopOnly("I need to stop smoking"))
    }

    func test_stopInsideSentence_stopAtPharmacy() {
        // "stop" is a physical stop (location visit)
        XCTAssertFalse(TranscriptFilter.isStopOnly("buy groceries and remind me to stop at the pharmacy"))
    }

    func test_stopInsideSentence_stopSubscription() {
        // "stop" as in halt a service
        XCTAssertFalse(TranscriptFilter.isStopOnly("call bank to stop the automatic payment"))
    }

    func test_doneInsideSentence_doneWithProject() {
        // User wants to tell someone they're done — that's a task, not a recording stop
        XCTAssertFalse(TranscriptFilter.isStopOnly("tell sarah I'm done with the project"))
    }

    func test_doneInsideSentence_doneWithChemo() {
        // "I'm done" refers to a medical milestone, not the recording session
        XCTAssertFalse(TranscriptFilter.isStopOnly("remind me that I'm done with chemo next week"))
    }

    func test_doneInsideSentence_doneByFriday() {
        // "done" describes a deadline, not the session state
        XCTAssertFalse(TranscriptFilter.isStopOnly("finish quarterly report done by Friday"))
    }

    func test_finishInsideSentence_finishReport() {
        // "finish" is the task action verb
        XCTAssertFalse(TranscriptFilter.isStopOnly("finish the quarterly report"))
    }

    func test_finishInsideSentence_finishPainting() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("finish painting the bedroom this weekend"))
    }

    func test_endInsideSentence_endMeeting() {
        // "end" is what John should do to the meeting
        XCTAssertFalse(TranscriptFilter.isStopOnly("call john to end the meeting early"))
    }

    func test_endInsideSentence_endSubscription() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("remind me to end my Netflix subscription"))
    }

    func test_allDoneInsideSentence_allDoneMarkers() {
        // "all done" is a brand/product name here
        XCTAssertFalse(TranscriptFilter.isStopOnly("buy all done markers from office depot"))
    }

    func test_allDoneInsideSentence_cancelAllDone() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("cancel all done tasks"))
    }

    func test_okInsideSentence_okLetMeThink() {
        // "ok" followed by more content — not a stop
        XCTAssertFalse(TranscriptFilter.isStopOnly("ok let me think about the dentist appointment"))
    }

    func test_okInsideSentence_okDentistAppointment() {
        // Brief task but "ok" is a filler, not a stop
        XCTAssertFalse(TranscriptFilter.isStopOnly("ok dentist appointment"))
    }

    // MARK: - Ambiguous single-word cases: should NOT trigger stop
    // Single ambiguous words are excluded from the phrase list on purpose —
    // they appear too frequently inside real tasks.

    func test_singleWord_stop_isNotStop() {
        // Alone, "stop" could be many things; safer to send to AI than silently discard
        XCTAssertFalse(TranscriptFilter.isStopOnly("stop"))
    }

    func test_singleWord_done_isNotStop() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("done"))
    }

    func test_singleWord_ok_isNotStop() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("ok"))
    }

    func test_singleWord_finish_isNotStop() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("finish"))
    }

    func test_singleWord_end_isNotStop() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("end"))
    }

    // MARK: - Multi-task transcripts with trailing closers (AI filler rule)
    // These are integration-level doc tests — they verify that the transcript
    // passes through isStopOnly so the AI receives it. Whether the AI correctly
    // strips the trailing "that's it" is tested in AIFillerRuleEvalTests.

    func test_passthrough_callDentistThatSIt() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("call dentist and make appointment that's it"))
    }

    func test_passthrough_buyGroceriesOkDone() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("buy milk eggs and bread ok done"))
    }

    func test_passthrough_payRentImDone() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("pay rent online I'm done"))
    }

    func test_passthrough_callFamilyThatSAll() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("call mom dad and sister that's all"))
    }

    func test_passthrough_exerciseThatSEverything() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("remind me to exercise tomorrow morning that's everything"))
    }

    func test_passthrough_cancelGymImDonePayingForIt() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("cancel gym membership I'm done paying for it"))
    }

    // MARK: - Empty and whitespace-only inputs

    func test_empty_isNotStop() {
        // Empty transcript is handled separately upstream; isStopOnly should be false
        XCTAssertFalse(TranscriptFilter.isStopOnly(""))
    }

    func test_whitespaceOnly_isNotStop() {
        XCTAssertFalse(TranscriptFilter.isStopOnly("   "))
    }
}
