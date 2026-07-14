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
        let t = text.lowercased()
        let words = Set(t.split { !$0.isLetter }.map(String.init))
        func word(_ ws: [String]) -> Bool { ws.contains { words.contains($0) } }
        func phrase(_ ps: [String]) -> Bool { ps.contains { t.contains($0) } }

        if word(["no", "nope", "cancel", "stop", "dont", "keep", "wait", "nevermind"])
            || phrase(["never mind", "don't", "do not", "keep them", "keep it", "leave it",
                       "leave them", "not now", "changed my mind"]) {
            return .cancel
        }
        if word(["yes", "yeah", "yep", "yup", "confirm", "confirmed", "delete", "proceed", "sure", "definitely"])
            || phrase(["do it", "go ahead", "delete all", "delete them", "wipe them", "wipe it",
                       "yes please", "get rid"]) {
            return .confirm
        }
        return nil
    }
}
