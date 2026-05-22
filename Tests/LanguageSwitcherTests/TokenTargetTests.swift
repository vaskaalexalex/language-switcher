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
