import CoreFoundation
import Testing
@testable import LanguageSwitcher

@Suite
struct TextReplacerValueTests {
    @Test
    func testReplaceTokenInGitPrefixLine() {
        let full = "main: e,рал"
        let result = TextReplacer.replaceToken(in: full, start: 6, length: 5, replacement: "убрал")
        #expect(result == "main: убрал")
    }

    @Test
    func testSnippetFromGitPrefixLine() {
        #expect(TextReplacer.snippet(from: "main: e,рал", start: 6, length: 5) == "e,рал")
    }

    @Test
    func testReplaceTokenOutOfRangeReturnsOriginal() {
        let full = "hello"
        #expect(TextReplacer.replaceToken(in: full, start: 10, length: 1, replacement: "x") == "hello")
    }

    @Test
    func testSelectionTokenTargetUsesExactRangeNotLastToken() {
        let full = "hello world"
        let range = CFRange(location: 0, length: 5)
        let target = TextReplacer.selectionTokenTarget(
            in: full, range: range, fallbackSnippet: "hello")
        #expect(target?.start == 0)
        #expect(target?.length == 5)
        #expect(target?.snippet == "hello")
    }

    @Test
    func testReplaceTokenWithMultiWordSelection() {
        let full = "hello world"
        let result = TextReplacer.replaceToken(
            in: full, start: 0, length: 5, replacement: "руддщ")
        #expect(result == "руддщ world")
    }

    @Test
    func testSelectionTokenTargetMidTextSelection() {
        let full = "one two three"
        let range = CFRange(location: 4, length: 3)
        let target = TextReplacer.selectionTokenTarget(
            in: full, range: range, fallbackSnippet: "two")
        #expect(target?.start == 4)
        #expect(target?.length == 3)
        #expect(target?.snippet == "two")
    }

    @Test
    func testSelectionTokenTargetFallsBackWhenSliceOutOfRange() {
        let range = CFRange(location: 0, length: 3)
        let target = TextReplacer.selectionTokenTarget(
            in: "ab", range: range, fallbackSnippet: "xyz")
        #expect(target?.snippet == "xyz")
    }

    @Test
    func testCaretPositionAfterReplacement() {
        #expect(TextReplacer.caretPositionAfterReplacement(start: 6, converted: "убрал") == 11)
        #expect(TextReplacer.caretPositionAfterReplacement(start: 0, converted: "hello") == 5)
    }
}
