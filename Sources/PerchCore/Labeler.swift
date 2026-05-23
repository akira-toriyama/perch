// Label-alphabet assignment. Given an alphabet `"asdfjkl..."` and a
// list of elements, produce one `Hint` per element with a typeable
// key sequence.
//
// Strategy:
//   - For ≤ |alphabet| elements: single-letter labels, alphabet
//     order. Elements closer to screen center get the earlier
//     (home-row) letters when `prioritiseCenter` is enabled.
//   - For > |alphabet| elements: extend to two-letter labels from
//     the same alphabet (a, s, …, l, aa, as, …). Two-letter labels
//     never collide with single-letter ones because no single
//     letter is reused as a two-letter prefix — the leading letters
//     used for two-letter labels are reserved up front.
//
// All logic is pure; the live overlay is rebuilt every time the
// frontmost focus changes, so memoising labels across enumerations
// would be a footgun (an element that disappears between frames
// would still have a label pointing nowhere).

import CoreGraphics
import Foundation

public enum Labeler {
    /// Assign a hint key sequence to every element in `elements`.
    /// Returns hints in the same order as inputs.
    public static func assign(
        elements: [UIElement],
        alphabet: String,
        prioritiseCenter: Bool,
        screenSize: CGSize
    ) -> [Hint] {
        guard !elements.isEmpty, !alphabet.isEmpty else { return [] }
        let chars = Array(alphabet)
        let n = elements.count

        // Order to assign letters in: center-first when configured,
        // else preserve enumeration order. Center-first scores by
        // squared distance from the screen midpoint so the most
        // prominent element gets the first alphabet letter (the home
        // row).
        let ordered: [(idx: Int, element: UIElement)]
        if prioritiseCenter {
            let cx = screenSize.width / 2
            let cy = screenSize.height / 2
            ordered = elements.enumerated()
                .map { (idx: $0.offset, element: $0.element) }
                .sorted { lhs, rhs in
                    let l = lhs.element.frame
                    let r = rhs.element.frame
                    let lx = l.midX - cx, ly = l.midY - cy
                    let rx = r.midX - cx, ry = r.midY - cy
                    return (lx * lx + ly * ly) < (rx * rx + ry * ry)
                }
        } else {
            ordered = elements.enumerated()
                .map { (idx: $0.offset, element: $0.element) }
        }

        var keysByOriginalIndex = [String](repeating: "", count: n)

        if n <= chars.count {
            // Single-letter labels — straightforward.
            for (rank, item) in ordered.enumerated() {
                keysByOriginalIndex[item.idx] = String(chars[rank])
            }
        } else {
            // Need two-letter labels for the overflow. Reserve the
            // tail of the alphabet as "prefix" letters: those will
            // ONLY appear as the first character of a two-letter
            // label, never as a single-letter label. That keeps the
            // single- and two-letter spaces disjoint so typing the
            // first character of a two-letter label can't briefly
            // match a single-letter label.
            //
            // We need enough prefixes so that |single| + |prefixes| *
            // |alphabet| ≥ n. The minimal valid split: smallest p such
            // that (|chars| − p) + p * |chars| ≥ n.
            var prefixCount = 0
            while (chars.count - prefixCount) + prefixCount * chars.count < n {
                prefixCount += 1
                if prefixCount >= chars.count { break }
            }
            let singleCount = chars.count - prefixCount
            let singles = Array(chars.prefix(singleCount))
            let prefixes = Array(chars.suffix(prefixCount))

            for (rank, item) in ordered.enumerated() {
                if rank < singles.count {
                    keysByOriginalIndex[item.idx] = String(singles[rank])
                } else {
                    let twoLetterRank = rank - singles.count
                    let p = twoLetterRank / chars.count
                    let s = twoLetterRank % chars.count
                    if p < prefixes.count {
                        keysByOriginalIndex[item.idx]
                            = "\(prefixes[p])\(chars[s])"
                    } else {
                        // Ran out of two-letter combinations — this
                        // is an "unreachable" element. Marking it
                        // empty signals the caller to drop the hint
                        // rather than show a blank pill.
                        keysByOriginalIndex[item.idx] = ""
                    }
                }
            }
        }

        return zip(elements, keysByOriginalIndex)
            .compactMap { e, k in k.isEmpty ? nil : Hint(keys: k, element: e) }
    }

    /// Filter hints whose keys start with `prefix`. Used by the
    /// controller as the user types one character at a time.
    public static func filter(hints: [Hint], prefix: String) -> [Hint] {
        guard !prefix.isEmpty else { return hints }
        return hints.filter { $0.keys.hasPrefix(prefix) }
    }

    /// Resolve a fully-typed key sequence to the unique matching
    /// hint (or `nil` if not unique / not found).
    public static func resolve(hints: [Hint], keys: String) -> Hint? {
        let exact = hints.filter { $0.keys == keys }
        return exact.count == 1 ? exact.first : nil
    }
}
