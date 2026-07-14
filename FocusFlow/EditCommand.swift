import Foundation

// Spoken commands for the edit sheet. The edit sheet listens continuously (like the
// capture screen) and interprets a whole spoken phrase, so you can say "change the title
// to buy groceries", "remove step 2", "add a step call the bank", or "save" without any
// tap. Extracted for unit testing (VoxdumpEditCommandTests).
enum EditCommand: Equatable {
    case setTitle(String)
    case addStep(String)
    case removeStep(Int)   // 1-based
    case removeLastStep
    case clearSteps
    case save
    case cancel
}

enum EditCommandMatcher {
    /// Interpret a finalized spoken phrase into an edit command, or nil to keep listening.
    /// Structured commands (title/add/remove/clear) are checked BEFORE the short save/cancel
    /// words so "change the title to save the report" sets the title rather than saving.
    static func match(_ text: String) -> EditCommand? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let words = t.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        let wordSet = Set(words)
        func has(_ ws: [String]) -> Bool { ws.contains { wordSet.contains($0) } }
        func phrase(_ ps: [String]) -> Bool { ps.contains { t.contains($0) } }

        // Clear every step.
        if phrase(["remove all steps", "remove all the steps", "remove all micro steps",
                   "remove all micro-steps", "clear all steps", "clear the steps", "clear steps",
                   "delete all steps", "delete all the steps", "delete all micro steps",
                   "remove the steps", "delete the steps", "remove every step"]) { return .clearSteps }

        // Remove a specific step: "remove step 2", "remove the first micro step", "remove last step".
        if has(["remove", "delete", "drop", "scratch"]) && (has(["step", "steps"]) || ordinal(words) != nil) {
            if has(["last"]) || phrase(["last one"]) { return .removeLastStep }
            if let n = stepNumber(words) { return .removeStep(n) }
            return nil   // "remove the step" with no number is ambiguous; keep listening
        }

        // Add a step: "add a step call the bank", "new step water plants".
        if has(["add", "new"]) && has(["step"]) {
            if let si = words.firstIndex(of: "step") {
                var rest = Array(words[(si + 1)...])
                while let f = rest.first, ["to", "a", "an", "the", "that"].contains(f) { rest.removeFirst() }
                let hint = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !hint.isEmpty { return .addStep(capitalizeFirst(hint)) }
            }
            return nil
        }

        // Set the title: "change/set/correct/update the title to X", "rename to X", "call it X".
        if let title = titleAfterMarker(t) { return .setTitle(title) }

        // Save (checked after structured commands so title/step content is not misread as save).
        if phrase(["save it", "save that", "looks good", "that's good", "thats good",
                   "all done", "that's it", "thats it", "i'm done", "im done"])
            || has(["save", "saved", "done", "confirm", "finished"]) { return .save }

        // Cancel / discard edits (kept tight so stray words do not throw away edits).
        if phrase(["never mind", "go back", "cancel that", "forget it", "discard it"])
            || has(["cancel", "discard", "nevermind"]) { return .cancel }

        return nil
    }

    // MARK: - Helpers

    private static let ordinals: [String: Int] = [
        "first": 1, "1st": 1, "one": 1,
        "second": 2, "2nd": 2, "two": 2,
        "third": 3, "3rd": 3, "three": 3,
        "fourth": 4, "4th": 4, "four": 4,
        "fifth": 5, "5th": 5, "five": 5
    ]

    private static func ordinal(_ words: [String]) -> Int? {
        for w in words { if let n = ordinals[w] { return n } }
        return nil
    }

    private static func stepNumber(_ words: [String]) -> Int? {
        for w in words { if let n = Int(w), n >= 1, n <= 20 { return n } }   // "step 2"
        return ordinal(words)                                               // "first"/"second"
    }

    private static func titleAfterMarker(_ t: String) -> String? {
        // Most-specific markers first; all the "title to/as" variants leave the same suffix.
        let markers = ["change the title to ", "set the title to ", "correct the title to ",
                       "update the title to ", "make the title ", "the title to ", "title to ",
                       "title as ", "title should be ", "title is ", "titled ",
                       "rename it to ", "rename this to ", "rename to ", "rename it ",
                       "call it ", "call this ", "name it ", "name this "]
        for m in markers {
            if let r = t.range(of: m) {
                let raw = String(t[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = trimTrailingFiller(raw)
                if !cleaned.isEmpty { return capitalizeFirst(cleaned) }
            }
        }
        return nil
    }

    private static func trimTrailingFiller(_ s: String) -> String {
        var words = s.split(separator: " ").map(String.init)
        let trailing: Set<String> = ["please", "now", "ok", "okay", "thanks", "thank", "you"]
        while let last = words.last, trailing.contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
