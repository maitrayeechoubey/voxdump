import Foundation

/// Pure logic for deciding whether a voice transcript is a stop signal vs. real content.
/// Extracted from BrainDumpSheet so it can be unit-tested without instantiating any views.
enum TranscriptFilter {

    // MARK: - Stop phrase detection

    /// Phrases that, when they ARE the entire transcript, mean "I'm done talking."
    /// Single ambiguous words ("stop", "done", "ok", "finish") are intentionally excluded
    /// because they appear naturally inside real sentences:
    ///   ✗ "remind me to call AT&T to stop calling me"
    ///   ✗ "I need to finish the quarterly report"
    ///   ✓ "stop recording"  (explicitly about recording)
    ///   ✓ "that's it"       (only makes sense as a closer)
    static let exactStopPhrases: Set<String> = [
        "that's it", "thats it",
        "that's all", "thats all",
        "that'll do",
        "i'm done", "im done",
        "ok done", "okay done",
        "all done",
        "stop recording", "end recording", "finish recording",
        "that's everything", "thats everything",
        "that's all for now", "thats all for now"
    ]

    /// Returns true only when the *entire* transcript is a stop signal.
    /// Partial matches anywhere inside a longer sentence always return false.
    static func isStopOnly(_ raw: String) -> Bool {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
        return exactStopPhrases.contains(normalized)
    }

    // MARK: - Abort phrase detection

    /// Phrases that, when they ARE the entire transcript on the capture screen, mean "cancel this,
    /// take me back" — so a spoken "cancel" dismisses the brain dump and returns to the
    /// always-listening surface instead of being parsed into a task and stranding the user on the
    /// non-listening ready screen. Whole-transcript match only, so a real dump that merely CONTAINS
    /// "cancel" ("cancel my subscription") is unaffected.
    static let exactAbortPhrases: Set<String> = [
        "cancel", "cancel that", "cancel this",
        "never mind", "nevermind",
        "go back", "back", "go home",
        "close", "close it", "close this",
        "forget it", "not now", "discard", "abort",
        "exit", "quit", "stop", "stop it", "stop recording", "stop listening",
        "nothing", "nothing else", "no thanks"
    ]

    /// Returns true only when the *entire* transcript is an abort/cancel signal.
    static func isAbort(_ raw: String) -> Bool {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
        return exactAbortPhrases.contains(normalized)
    }
}
