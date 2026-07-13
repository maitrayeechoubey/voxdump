import Foundation

/// Fuzzy matching of a spoken/paraphrased task hint to an existing task title.
///
/// Replaces the previous raw bidirectional `contains` check used by the
/// completeNamed / deleteNamed / reactivateNamed commands. That check silently
/// failed whenever the on-device model padded the hint with an extra word
/// ("milk task" vs. title "Buy milk") or echoed the whole sentence
/// ("mark the xfinity task as done"), because neither direction of `.contains`
/// held. See workspace/qa-handoff-named-commands.md (bug #2).
///
/// Strategy: strip command verbs and generic filler ("task", "the", "done", …)
/// from both sides, then score by shared significant tokens. A match must clear
/// a confidence threshold so an ambiguous hint (e.g. "call mom" vs. "Call dad")
/// resolves to no match rather than completing the wrong task.
enum TaskMatcher {
    /// Words that carry no identifying signal: articles, possessives, leaked
    /// command verbs, generic task nouns, and common time/glue words.
    static let stopWords: Set<String> = [
        "the", "a", "an", "my", "your", "this", "that", "to", "of", "for",
        "task", "tasks", "item", "items", "thing", "things", "reminder",
        "todo", "list",
        "mark", "complete", "completed", "finish", "finished", "done", "do",
        "delete", "remove", "clear", "cancel", "reactivate", "uncomplete",
        "unmark", "uncheck", "bring", "back", "undo", "check", "off", "as",
        "not", "please", "it", "is", "was", "already", "just", "so", "you",
        "can", "and", "today", "tonight", "tomorrow"
    ]

    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func significantTokens(_ s: String) -> Set<String> {
        Set(tokens(s).filter { !stopWords.contains($0) })
    }

    /// Index of the best-matching title for `hint`, or nil if none is a
    /// confident match. `titles` should be ordered by the caller's preferred
    /// tie-break (e.g. most-recent first) so equal scores resolve to index 0.
    static func bestMatchIndex(hint: String, titles: [String]) -> Int? {
        let h = hint.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }

        // Exact normalized title equality wins outright.
        if let i = titles.firstIndex(where: {
            $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == h
        }) {
            return i
        }

        let hSig = significantTokens(h)
        var best: (idx: Int, score: Double)?
        for (i, title) in titles.enumerated() {
            let score = overlapScore(hSig, significantTokens(title))
            if score > 0, best == nil || score > best!.score {
                best = (i, score)
            }
        }
        // Require better than a single shared token between equal-size sets
        // (which scores exactly 0.5) to avoid acting on the wrong task.
        if let best, best.score > 0.5 { return best.idx }
        return nil
    }

    private static func overlapScore(_ hSig: Set<String>, _ tSig: Set<String>) -> Double {
        guard !hSig.isEmpty, !tSig.isEmpty else { return 0 }
        let inter = hSig.intersection(tSig).count
        guard inter > 0 else { return 0 }
        // Coverage of the smaller significant-token set: "milk" ⊂ "buy milk" → 1.0,
        // "call xfinity today" ⊃ "call xfinity" → 1.0, "call mom" vs "call dad" → 0.5.
        return Double(inter) / Double(min(hSig.count, tSig.count))
    }
}
