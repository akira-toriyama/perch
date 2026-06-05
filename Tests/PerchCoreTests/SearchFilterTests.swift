import XCTest
@testable import PerchCore

final class SearchFilterTests: XCTestCase {

    // MARK: - subsequenceScore

    /// Substring match scores at least as well as a same-length
    /// subsequence-with-gaps match. "Exact prefix still wins" — the
    /// no-regression guarantee from the issue (so typing the first
    /// keystroke surfaces the obvious prefix matches first).
    func testSubstringBeatsSubsequenceWithGap() {
        // "ab" appears as a substring in "abcdef" but only as a
        // gapped subsequence in "a_b_cdef".
        let substr = SearchFilter.subsequenceScore(
            query: "ab", target: "abcdef")
        let gapped = SearchFilter.subsequenceScore(
            query: "ab", target: "a_b_cdef")
        XCTAssertNotNil(substr)
        XCTAssertNotNil(gapped)
        XCTAssertGreaterThan(substr!, gapped!)
    }

    /// Match at a word boundary should rank above the same-length
    /// match buried mid-word. `cls` lands on the boundary in
    /// "Close Tab" but mid-word in "ApplauseClasses".
    func testWordBoundaryBeatsMidWord() {
        let boundary = SearchFilter.subsequenceScore(
            query: "cls", target: "close tab")
        let midWord = SearchFilter.subsequenceScore(
            query: "cls", target: "applauseclasses")
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(midWord)
        XCTAssertGreaterThan(boundary!, midWord!)
    }

    /// No match returns nil — the caller drops the element.
    func testReturnsNilOnNoMatch() {
        XCTAssertNil(SearchFilter.subsequenceScore(
            query: "xyz", target: "close tab"))
        // Order matters — chars of `cba` are present individually
        // but never in the right sequence.
        XCTAssertNil(SearchFilter.subsequenceScore(
            query: "cba", target: "abc"))
    }

    /// Empty query is a no-op — score 0, never nil. Matches the
    /// caller's idle-state contract (no query → all elements pass).
    func testEmptyQueryReturnsZero() {
        XCTAssertEqual(
            SearchFilter.subsequenceScore(query: "", target: "any"), 0)
    }

    // MARK: - expand (synonym lookup)

    /// Synonym table is bidirectional within a group. Typing the
    /// key OR any value should bring back the whole group, so the
    /// user doesn't have to remember which form the config uses
    /// as the canonical key.
    func testSynonymExpansionIsBidirectional() {
        let syn = ["delete": ["remove", "trash", "rm"]]
        // From the key: pulls in every value.
        let fromKey = Set(SearchFilter.expand(
            token: "delete", synonyms: syn))
        XCTAssertEqual(fromKey,
                       Set(["delete", "remove", "trash", "rm"]))
        // From a value: pulls in the key + sibling values.
        let fromValue = Set(SearchFilter.expand(
            token: "rm", synonyms: syn))
        XCTAssertEqual(fromValue,
                       Set(["delete", "remove", "trash", "rm"]))
    }

    /// Tokens not present in any group expand to themselves only —
    /// no false matches across groups.
    func testUnrelatedTokenIsUnchanged() {
        let syn = ["delete": ["remove", "trash", "rm"]]
        XCTAssertEqual(
            SearchFilter.expand(token: "open", synonyms: syn),
            ["open"])
    }

    // MARK: - rank (end-to-end)

    /// Acceptance: `Cls` against Safari-style labels surfaces
    /// "Close Tab" / "Close Window". This is the fuzzy-only path;
    /// no synonym table needed.
    func testRankCls_MatchesCloseTabAndWindow() {
        let items = [
            uiElement(id: "1", label: "Close Tab"),
            uiElement(id: "2", label: "Close Window"),
            uiElement(id: "3", label: "Reload Page"),
        ]
        let ranked = SearchFilter.rank(
            tokens: ["Cls"], elements: items)
        let ids = ranked.map(\.element.id)
        XCTAssertEqual(Set(ids), Set(["1", "2"]))
    }

    /// Acceptance: `rm tab` (synonym `rm` → `delete`/`remove`) surfaces
    /// "Remove Tab" AND "Delete Tab". `tab` matches as substring on
    /// both; `rm` matches "Remove" directly and "Delete" via synonym.
    func testRankRmTab_HitsRemoveAndDeleteViaSynonym() {
        let items = [
            uiElement(id: "1", label: "Remove Tab"),
            uiElement(id: "2", label: "Delete Tab"),
            uiElement(id: "3", label: "New Tab"),
            uiElement(id: "4", label: "Close Window"),
        ]
        let synonyms = ["delete": ["remove", "trash", "rm"]]
        let ranked = SearchFilter.rank(
            tokens: ["rm", "tab"],
            elements: items,
            synonyms: synonyms)
        let ids = ranked.map(\.element.id)
        XCTAssertTrue(ids.contains("1"), "Remove Tab should match")
        XCTAssertTrue(ids.contains("2"), "Delete Tab should match via rm→delete")
        XCTAssertFalse(ids.contains("3"), "New Tab has no rm-equivalent")
        XCTAssertFalse(ids.contains("4"), "Close Window has no tab token")
    }

    /// No-regression: single-keystroke queries (`f`) still hit every
    /// label containing that letter — same set as the old
    /// `.contains` filter, just re-ranked.
    func testSingleCharNoRegression() {
        let items = [
            uiElement(id: "1", label: "File"),
            uiElement(id: "2", label: "Foo"),
            uiElement(id: "3", label: "Bar"),
        ]
        let ranked = SearchFilter.rank(
            tokens: ["f"], elements: items)
        let ids = Set(ranked.map(\.element.id))
        XCTAssertEqual(ids, Set(["1", "2"]))
    }

    /// Empty token list returns every element in input order with
    /// score 0 — SearchMode shows the first N as a "preview" before
    /// the user types.
    func testEmptyTokensReturnsEverythingInOrder() {
        let items = [
            uiElement(id: "1", label: "A"),
            uiElement(id: "2", label: "B"),
            uiElement(id: "3", label: "C"),
        ]
        let ranked = SearchFilter.rank(tokens: [], elements: items)
        XCTAssertEqual(ranked.map(\.element.id), ["1", "2", "3"])
        XCTAssertTrue(ranked.allSatisfy { $0.score == 0 })
    }

    /// Direct-token match outranks a synonym-only match on the same
    /// label, so `delete` against "Delete Tab" ranks above "Remove
    /// Tab" (which matches `delete` only via synonym).
    func testDirectTokenBeatsSynonymOnEqualLabel() {
        let items = [
            uiElement(id: "delete", label: "Delete Tab"),
            uiElement(id: "remove", label: "Remove Tab"),
        ]
        let synonyms = ["delete": ["remove"]]
        let ranked = SearchFilter.rank(
            tokens: ["delete"],
            elements: items,
            synonyms: synonyms)
        XCTAssertEqual(ranked.first?.element.id, "delete")
    }

    /// AND-matching across tokens: every token (or one of its
    /// expansions) must match. A label that only matches one of
    /// two query tokens is dropped.
    func testAllTokensMustMatch() {
        let items = [
            uiElement(id: "1", label: "Close Tab"),
            uiElement(id: "2", label: "Close Window"),
        ]
        // "tab" only matches id 1.
        let ranked = SearchFilter.rank(
            tokens: ["close", "tab"], elements: items)
        XCTAssertEqual(ranked.map(\.element.id), ["1"])
    }

    /// Ties (equal score) preserve input order. Same score for two
    /// identical labels → first one stays first. This pins the
    /// no-shuffle promise for single-keystroke queries.
    func testTiesAreStable() {
        let items = [
            uiElement(id: "a", label: "Same"),
            uiElement(id: "b", label: "Same"),
            uiElement(id: "c", label: "Same"),
        ]
        let ranked = SearchFilter.rank(
            tokens: ["s"], elements: items)
        XCTAssertEqual(ranked.map(\.element.id), ["a", "b", "c"])
    }

    // MARK: - helpers

    private func uiElement(id: String, label: String) -> UIElement {
        UIElement(id: id, role: "Button",
                  label: label, frame: .zero)
    }
}
