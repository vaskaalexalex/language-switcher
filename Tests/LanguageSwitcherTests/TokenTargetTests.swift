import Testing
@testable import LanguageSwitcher

@Suite
struct TokenTargetTests {
    @Test
    func testEmptyOrWhitespaceOnlyTextReturnsNil() {
        #expect(TextReplacer.computeTokenTarget(in: "", caretHint: nil) == nil)
        #expect(TextReplacer.computeTokenTarget(in: "   \n\t", caretHint: nil) == nil)
    }

    @Test
    func testTokenAtEndOfText() {
        expectToken(TextReplacer.computeTokenTarget(in: "hello", caretHint: 5), 0, 5, "hello")
        expectToken(TextReplacer.computeTokenTarget(in: "hello world", caretHint: 11), 6, 5, "world")
    }

    @Test
    func testMidWordCaretDoesNotSnapToEnd() {
        expectToken(TextReplacer.computeTokenTarget(in: "hello world", caretHint: 3), 0, 3, "hel")
        expectToken(TextReplacer.computeTokenTarget(in: "привет, мир", caretHint: 7), 0, 7, "привет,")
    }

    @Test
    func testCaretAfterWhitespaceSelectsPreviousToken() {
        expectToken(TextReplacer.computeTokenTarget(in: "hello world", caretHint: 6), 0, 5, "hello")
        expectToken(TextReplacer.computeTokenTarget(in: "hello   ", caretHint: 8), 0, 5, "hello")
    }

    @Test
    func testMissingOrInvalidCaretFallsBackToEffectiveEnd() {
        expectToken(TextReplacer.computeTokenTarget(in: "hello world", caretHint: nil), 6, 5, "world")
        expectToken(TextReplacer.computeTokenTarget(in: "hello world", caretHint: 0), 6, 5, "world")
        expectToken(TextReplacer.computeTokenTarget(in: "hello world", caretHint: 99), 6, 5, "world")
    }

    @Test
    func testMultilineTextUsesWhitespaceBoundaries() {
        expectToken(TextReplacer.computeTokenTarget(in: "foo\nbar", caretHint: 7), 4, 3, "bar")
    }

    @Test
    func testNonWhitespacePunctuationBelongsToToken() {
        expectToken(TextReplacer.computeTokenTarget(in: "(hello)", caretHint: 7), 0, 7, "(hello)")
    }

    @Test
    func testGitPrefixWithEmptyWordReturnsNil() {
        #expect(TextReplacer.computeTokenTarget(in: "main: ", caretHint: 6) == nil)
    }

    @Test
    func testGitPrefixWithWordAtEnd() {
        expectToken(TextReplacer.computeTokenTarget(in: "main: убрал", caretHint: 11), 6, 5, "убрал")
        expectToken(TextReplacer.computeTokenTarget(in: "main: e,рал", caretHint: 11), 6, 5, "e,рал")
    }

    @Test
    func testStaleAXValueCaretBeyondTextFallsBackToLastToken() {
        // Cursor file-chip: AXValue lags (shows "k") while caret is far ahead.
        expectToken(TextReplacer.computeTokenTarget(in: "k", caretHint: 221), 0, 1, "k")
    }

    // MARK: - Trailing-whitespace / punctuation span consistency (BUG 2)

    @Test
    func testPunctuatedWordWithTrailingSpaceIsNotSkipped() {
        // Regression: caret in the trailing space after a word that ends in
        // punctuation used to return nil (silent no-op). It must select the
        // word the same way the in-caret branch does one char earlier.
        expectToken(TextReplacer.computeTokenTarget(in: "hello, ", caretHint: 7), 0, 6, "hello,")
        expectToken(TextReplacer.computeTokenTarget(in: "привет; ", caretHint: 8), 0, 7, "привет;")
        expectToken(TextReplacer.computeTokenTarget(in: "code) ", caretHint: 6), 0, 5, "code)")
    }

    @Test
    func testTrailingWhitespaceSpanMatchesInCaretSpan() {
        // The span the trailing-whitespace branch returns must equal the span
        // the in-caret branch returns one position earlier.
        let trailing = TextReplacer.computeTokenTarget(in: "world, ", caretHint: 7)
        let inCaret = TextReplacer.computeTokenTarget(in: "world, ", caretHint: 6)
        #expect(trailing?.start == inCaret?.start)
        #expect(trailing?.length == inCaret?.length)
        #expect(trailing?.snippet == inCaret?.snippet)
        #expect(trailing?.snippet == "world,")
    }

    @Test
    func testGitPrefixWithTrailingSpaceStillReturnsNil() {
        // A "prefix:" marker followed by a space is still nothing to convert.
        #expect(TextReplacer.computeTokenTarget(in: "main: ", caretHint: 6) == nil)
        #expect(TextReplacer.computeTokenTarget(in: "feat/x: ", caretHint: 8) == nil)
    }

    @Test
    func testPunctuationOnlyWordWithTrailingSpaceReturnsNil() {
        // No letters -> nothing meaningful to convert.
        #expect(TextReplacer.computeTokenTarget(in: "... ", caretHint: 4) == nil)
        #expect(TextReplacer.computeTokenTarget(in: "?! ", caretHint: 3) == nil)
    }

    @Test
    func testMultipleTrailingSpacesAfterPunctuatedWord() {
        expectToken(TextReplacer.computeTokenTarget(in: "hello,   ", caretHint: 9), 0, 6, "hello,")
    }

    @Test
    func testTabAndNewlineAreWordBoundaries() {
        expectToken(TextReplacer.computeTokenTarget(in: "foo\tbar", caretHint: 7), 4, 3, "bar")
        expectToken(TextReplacer.computeTokenTarget(in: "foo\n\nbar", caretHint: 8), 5, 3, "bar")
    }

    @Test
    func testLeadingWhitespaceDoesNotShiftToken() {
        expectToken(TextReplacer.computeTokenTarget(in: "   hello", caretHint: 8), 3, 5, "hello")
    }

    // Documents the deliberate divergence between the trailing-whitespace
    // branch and the in-caret branch. These tokens are LayoutConverter no-ops
    // or prefix markers, so the asymmetry is harmless.

    @Test
    func testDigitOnlyWordWithTrailingSpaceReturnsNil() {
        // No letter -> trailing-whitespace branch declines (in-caret would not).
        #expect(TextReplacer.computeTokenTarget(in: "123 ", caretHint: 4) == nil)
    }

    @Test
    func testInCaretBranchStillReturnsPrefixMarker() {
        // With the caret right after the marker (no trailing space) the
        // in-caret branch returns it as-is; only the trailing-whitespace branch
        // filters "prefix:" out.
        expectToken(TextReplacer.computeTokenTarget(in: "main:", caretHint: 5), 0, 5, "main:")
    }

    private func expectToken(
        _ actual: (start: Int, length: Int, snippet: String)?,
        _ start: Int,
        _ length: Int,
        _ snippet: String
    ) {
        #expect(actual?.start == start)
        #expect(actual?.length == length)
        #expect(actual?.snippet == snippet)
    }
}
