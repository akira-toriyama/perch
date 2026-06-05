// Fuzzy + synonym filter pipeline used by SearchMode / MenuMode.
// Issue #53.
//
// The old `recompute()` in SearchMode did two passes:
//
//   1. Split query on whitespace into AND'd substring tokens.
//   2. Keep elements whose lowercased label `.contains` every token.
//
// That misses two whole classes of intent:
//
//   - Typos / shorthand:  `Cls`   → "Close Tab"
//                         `prfs`  → "Preferences…"
//                         `addr`  → "Address Bar"
//   - Synonyms:           `rm`    → "Delete" (via [search.synonyms])
//                         `quit`  → "Close"
//
// `SearchFilter` swallows both. Public surface:
//
//   - `subsequenceScore(query:target:)` — pure scorer. Returns nil
//     when `query` is NOT a subsequence of `target`; otherwise an
//     int where higher = better. Boundary / consecutive bonuses,
//     gap / start-position penalties.
//   - `rank(tokens:elements:synonyms:)` — combines per-token
//     scoring with synonym expansion and AND-matching across
//     tokens. Original input order is preserved on ties so single-
//     char queries don't shuffle visibly (no-regression rule from
//     the issue).
//
// Pure logic — no AppKit / no AX. Lives in PerchCore so MenuMode
// (#52) and any future search-flavour mode share the same ranker.

import Foundation

public enum SearchFilter {

    /// Result of ranking — the element with the score that earned
    /// its slot. Higher score = closer match. Score is opaque
    /// (only relative ordering matters); don't surface it in UI.
    public struct Ranked: Sendable, Equatable {
        public let element: UIElement
        public let score: Int
        public init(element: UIElement, score: Int) {
            self.element = element
            self.score = score
        }
    }

    /// Rank `elements` against `tokens`, expanding each token through
    /// `synonyms` before matching. AND-matching across tokens: an
    /// element is kept iff every token (or one of its expansions)
    /// matches the element's label.
    ///
    /// Empty `tokens` returns `elements` unfiltered, in input order,
    /// with score 0. This preserves SearchMode's "show me the first
    /// N before I type anything" idle behaviour.
    ///
    /// Ties (equal score) preserve the input order — important for
    /// single-keystroke queries where the user expects the first
    /// match they were already looking at to stay near the top.
    public static func rank(
        tokens: [String],
        elements: [UIElement],
        synonyms: [String: [String]] = [:]
    ) -> [Ranked] {
        if tokens.isEmpty {
            return elements.map { Ranked(element: $0, score: 0) }
        }

        // Pre-expand each token once so the per-element loop doesn't
        // walk the synonym table N times. The token itself is always
        // included; non-original expansions get a small penalty at
        // scoring time so e.g. typing `delete` still beats typing
        // `rm` on a "Delete" label.
        let expansions: [(token: String, forms: [(String, isOriginal: Bool)])]
            = tokens.map { tok in
                let lowered = tok.lowercased()
                let exp = expand(token: lowered, synonyms: synonyms)
                let forms: [(String, Bool)] = exp.map {
                    ($0, $0 == lowered)
                }
                return (lowered, forms)
            }

        var ranked: [(Int, Int, Ranked)] = []   // (-score, index, item)
        ranked.reserveCapacity(elements.count)

        for (idx, e) in elements.enumerated() {
            let label = e.label.lowercased()
            var total = 0
            var matched = true
            for (_, forms) in expansions {
                var best: Int? = nil
                for (form, isOriginal) in forms {
                    guard let s = subsequenceScore(
                        query: form, target: label) else { continue }
                    let adjusted = isOriginal ? s : max(s - synonymPenalty, 1)
                    if best == nil || adjusted > best! { best = adjusted }
                }
                guard let b = best else { matched = false; break }
                total += b
            }
            if matched {
                ranked.append((-total, idx,
                               Ranked(element: e, score: total)))
            }
        }
        // Sort: best score first (we stored -score), then by original
        // index to keep ties stable.
        ranked.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            return a.1 < b.1
        }
        return ranked.map { $0.2 }
    }

    /// Score `query` as a subsequence match against `target`. Both
    /// inputs should be lowercased by the caller (no re-allocation
    /// per element). Returns `nil` when `target` does not contain
    /// every char of `query` in order.
    ///
    /// Scoring rules:
    ///   - +1 per matched char (the floor).
    ///   - **+8 ONLY on the first matched char** when that position
    ///     is a word boundary (start of string OR previous char is
    ///     non-alphanumeric). This is what makes `cls` rank
    ///     "Close Tab" above "ApplauseClass" — the start-of-word
    ///     anchor matters; boundaries hit mid-gap don't.
    ///     A boundary bonus on subsequent matches would let
    ///     `ab` in "a_b_cdef" (boundary on `b`) outscore "abcdef"
    ///     (contiguous), which is wrong.
    ///   - +4 when a matched char is immediately after the previous
    ///     match (no gap). Substrings get the maximum consecutive
    ///     bonus, which is the "exact prefix still wins" rule.
    ///   - -1 per char of gap inside the matched span.
    ///   - -1 per char of leading skip before the first match
    ///     (capped at 10 so very long labels don't dominate).
    ///
    /// Greedy left-to-right match — fast, and good enough for
    /// the SearchMode case (titles are short). A non-greedy
    /// optimiser is possible but adds code complexity not yet
    /// justified by user reports.
    public static func subsequenceScore(
        query: String, target: String
    ) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.unicodeScalars)
        let t = Array(target.unicodeScalars)
        var qi = 0
        var score = 0
        var prevMatchedAt = -2
        var firstMatchedAt = -1
        var ti = 0
        while ti < t.count && qi < q.count {
            if t[ti] == q[qi] {
                score += 1
                if firstMatchedAt < 0 {
                    // Anchor: first matched char gets the
                    // word-boundary bonus when it lands at a
                    // word start. Subsequent matches don't —
                    // see the doc above for the "a_b" pitfall.
                    let prev: Unicode.Scalar? =
                        ti > 0 ? t[ti - 1] : nil
                    let isBoundary: Bool
                    if let p = prev {
                        isBoundary = !isAlphanumeric(p)
                    } else {
                        isBoundary = true
                    }
                    if isBoundary { score += 8 }
                    firstMatchedAt = ti
                } else if ti == prevMatchedAt + 1 {
                    score += 4
                }
                prevMatchedAt = ti
                qi += 1
            }
            ti += 1
        }
        if qi < q.count { return nil }
        // Gap inside the matched span — "abc" in "a_b_c" pays 2.
        let span = prevMatchedAt - firstMatchedAt + 1
        let gap = max(0, span - q.count)
        score -= gap
        // Leading skip before the first match — "x" in "abcx" pays 3.
        score -= min(firstMatchedAt, 10)
        return max(score, 1)
    }

    // MARK: - Synonym expansion

    /// Penalty subtracted from the subsequenceScore when a match
    /// landed via a synonym expansion (not the original token).
    /// Small enough that synonym matches still rank ahead of
    /// non-matches, but large enough that an exact-token match
    /// beats a synonym match on the same label.
    private static let synonymPenalty = 4

    /// Return `token` plus every synonym form transitively reachable
    /// through `synonyms`. The table is treated as bidirectional:
    /// `close = ["shut", "quit", "kill"]` makes any of
    /// {"close", "shut", "quit", "kill"} expand to the full set, so
    /// a user can type any form and find any of the others without
    /// having to know which one is the table's key.
    static func expand(
        token: String, synonyms: [String: [String]]
    ) -> [String] {
        if synonyms.isEmpty { return [token] }
        var out: [String] = [token]
        var seen: Set<String> = [token]
        for (key, values) in synonyms {
            let k = key.lowercased()
            let vs = values.map { $0.lowercased() }
            // Group membership check — is the token equal to the
            // key OR one of the values?
            if k == token || vs.contains(token) {
                if !seen.contains(k) { seen.insert(k); out.append(k) }
                for v in vs where !seen.contains(v) {
                    seen.insert(v); out.append(v)
                }
            }
        }
        return out
    }

    /// `Unicode.Scalar` doesn't carry the `Character.isLetter` API,
    /// so check against the alphanumeric general categories directly.
    /// Matches the boundaries a human reader would identify:
    /// `_`, `-`, `.`, space, …  → boundary; `a`-`z`, `A`-`Z`, `0`-`9`,
    /// and accented letters → not a boundary.
    private static func isAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        let props = s.properties.generalCategory
        switch props {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }
}
