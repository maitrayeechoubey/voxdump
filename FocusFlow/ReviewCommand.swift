import Foundation

// Spoken commands available on the review card and its edit sheet. Extracted from
// CardReviewView so the matching rules are unit-testable and regressions are caught
// (the 2026-07-13 "accept never fires" bug was an untested matcher on the card).
enum ReviewCommand: Equatable {
    case accept, decline, edit, done   // review card
    case save, cancel                  // edit sheet
}

enum ReviewCommandMatcher {
    /// Map a (possibly partial) spoken transcript to a review command.
    /// - Parameter editing: true while the edit sheet is open, which swaps the
    ///   vocabulary to save/cancel so card words do not fire behind the sheet.
    ///
    /// Matching is on whole words (not substrings) so "broke" != "ok" and
    /// "yesterday" != "yes". The vocabulary includes common misrecognitions
    /// (accept -> "except") and short, reliably-recognized affirmatives ("yes",
    /// "ok", "yeah") so a flaky word like "accept" is never the only way through.
    static func match(_ text: String, editing: Bool) -> ReviewCommand? {
        let t = text.lowercased()
        let words = Set(t.split { !($0.isLetter || $0.isNumber) }.map(String.init))
        func word(_ ws: [String]) -> Bool { ws.contains { words.contains($0) } }
        func phrase(_ ps: [String]) -> Bool { ps.contains { t.contains($0) } }

        if editing {
            if word(["save", "saved", "keep", "done", "confirm", "ok", "okay"])
                || phrase(["save it", "save that", "looks good", "that's good"]) { return .save }
            if word(["cancel", "discard", "nevermind", "back", "close"])
                || phrase(["never mind", "go back", "cancel that", "forget it"]) { return .cancel }
            return nil
        }
        if word(["accept", "except", "keep", "yes", "yeah", "yep", "yup", "ok", "okay", "okey", "save", "saved", "add", "sure", "confirm", "confirmed", "approve"])
            || phrase(["add it", "sounds good", "looks good", "keep it", "yes please"]) { return .accept }
        if word(["decline", "skip", "discard", "reject", "delete", "remove", "trash", "nope", "no", "pass"])
            || phrase(["no thanks", "skip it", "get rid", "not now"]) { return .decline }
        if word(["edit", "change", "modify", "rename", "fix"])
            || phrase(["change it", "change the", "edit it", "let me edit"]) { return .edit }
        if word(["done", "finished", "finish", "stop", "exit", "quit"])
            || phrase(["that's all", "thats all", "i'm done", "im done", "all done", "that's it", "thats it"]) { return .done }
        return nil
    }
}

enum ConfirmVerdict: Equatable { case confirm, cancel }

// Interprets a spoken reply to a destructive confirmation ("Delete all N tasks? Say yes or no").
enum BulkDeleteConfirmMatcher {
    /// Cancel is checked FIRST and the bar for confirm is a clear affirmative, so anything
    /// ambiguous never wipes. Returns nil for unclear replies (keep listening, never auto-confirm).
    static func match(_ text: String) -> ConfirmVerdict? {
        let raw = text.lowercased()
        // A question is never authorization to wipe ("delete what?", "do you want to delete").
        if raw.contains("?") { return nil }
        // Any contraction negation (don't, won't, can't, wouldn't, ...) cancels.
        if raw.contains("n't") { return .cancel }
        // Normalize: non-alphanumerics -> spaces, collapse runs. NO filler-stripping: a bare
        // imperative preceded by a non-affirming marker ("so delete", "just delete", "um proceed")
        // must NOT match, so the few allowed filler+affirmative combos ("ok yes") are explicit
        // whitelist members below instead of being produced by a strip.
        let norm = String(raw.map { ($0.isLetter || $0.isNumber) ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
        let words = Set(norm.split(separator: " ").map(String.init))
        func word(_ ws: [String]) -> Bool { ws.contains { words.contains($0) } }

        // Negation cue anywhere -> never delete (checked before any affirmative).
        let negation = ["no", "not", "nope", "never", "nah", "cancel", "stop", "keep", "wait",
                        "nevermind", "maybe", "unsure", "dunno", "hold", "rather", "abort", "scratch",
                        "forget", "negative", "dont", "wont", "cant", "cannot", "aint"]
        if word(negation) || norm.contains("never mind") || norm.contains("changed my mind") { return .cancel }

        // Confirm ONLY if the WHOLE normalized reply is a known affirmation. A sentence that merely
        // CONTAINS "delete"/"confirm"/"yes" (a question, sarcasm, echo, or reluctant aside) is not
        // enough to authorize an irreversible wipe. Anything unrecognized returns nil (keep listening).
        let confirmSet: Set<String> = [
            "yes", "yeah", "yep", "yup", "ya", "yea", "yes sir",
            "ok yes", "okay yes", "yes ok", "yes okay", "yeah ok",
            "yes do it", "yeah do it", "yes go ahead", "yes delete", "yes delete them",
            "yes delete it", "yes delete all", "yes confirm", "yes wipe them", "yes proceed",
            "confirm", "confirm it", "confirmed", "confirm delete", "i confirm",
            "do it", "just do it", "go ahead", "go for it",
            "delete", "delete it", "delete them", "delete all", "delete them all",
            "delete everything", "delete it all", "delete them now", "delete now",
            "wipe them", "wipe it", "wipe them all", "wipe everything",
            "get rid of them", "clear them", "clear it",
            "proceed", "definitely", "absolutely", "for sure", "affirmative",
            "yes please", "yes absolutely", "yes definitely", "yes delete everything",
            "delete all of them", "delete all my tasks", "delete all tasks", "clear everything"
        ]
        return confirmSet.contains(norm) ? .confirm : nil
    }
}
