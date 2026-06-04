import CoreFoundation
import Foundation
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

    @Test
    func testCaretPositionUsesUtf16LengthForCyrillic() {
        // Cyrillic letters are single UTF-16 units, so the caret offset after a
        // 5-letter Russian word starting at 0 is 5.
        #expect(TextReplacer.caretPositionAfterReplacement(start: 0, converted: "привет") == 6)
    }

    // MARK: - Surrogate-pair / composed-sequence safety

    @Test
    func testSnippetRefusesToSplitSurrogatePair() {
        // "a👍b": 👍 occupies UTF-16 indices 1...2. A range that covers only
        // half the pair must not produce a broken half-character.
        #expect(("a👍b" as NSString).length == 4)
        #expect(TextReplacer.snippet(from: "a👍b", start: 1, length: 1) == nil)
        #expect(TextReplacer.snippet(from: "a👍b", start: 2, length: 1) == nil)
    }

    @Test
    func testSnippetAcceptsAlignedSurrogateRange() {
        #expect(TextReplacer.snippet(from: "a👍b", start: 1, length: 2) == "👍")
        #expect(TextReplacer.snippet(from: "a👍b", start: 0, length: 1) == "a")
    }

    @Test
    func testReplaceTokenRefusesToSplitSurrogatePair() {
        // Splitting the pair would corrupt the glyph -> return the text intact.
        #expect(TextReplacer.replaceToken(in: "a👍b", start: 1, length: 1, replacement: "X") == "a👍b")
    }

    @Test
    func testReplaceTokenAcceptsAlignedSurrogateRange() {
        #expect(TextReplacer.replaceToken(in: "a👍b", start: 1, length: 2, replacement: "X") == "aXb")
    }

    @Test
    func testSnippetOutOfRangeReturnsNil() {
        #expect(TextReplacer.snippet(from: "hi", start: 0, length: 5) == nil)
        #expect(TextReplacer.snippet(from: "hi", start: -1, length: 1) == nil)
        #expect(TextReplacer.snippet(from: "hi", start: 1, length: 0) == nil)
    }

    @Test
    func testReplaceTokenAtStartMiddleEnd() {
        #expect(TextReplacer.replaceToken(in: "abc def ghi", start: 0, length: 3, replacement: "X") == "X def ghi")
        #expect(TextReplacer.replaceToken(in: "abc def ghi", start: 4, length: 3, replacement: "X") == "abc X ghi")
        #expect(TextReplacer.replaceToken(in: "abc def ghi", start: 8, length: 3, replacement: "X") == "abc def X")
    }

    @Test
    func testReplaceTokenRefusesToSplitCombiningSequence() {
        // "e\u{0301}b": the combining acute is at UTF-16 index 1; replacing only
        // [1,1] would orphan the mark. The text must come back intact.
        let s = "e\u{0301}b"
        #expect((s as NSString).length == 3)
        #expect(TextReplacer.replaceToken(in: s, start: 1, length: 1, replacement: "X") == s)
        #expect(TextReplacer.snippet(from: s, start: 1, length: 1) == nil)
        // The aligned grapheme (e + combining mark = indices 0...1) is fine.
        #expect(TextReplacer.snippet(from: s, start: 0, length: 2) == "e\u{0301}")
    }

    // MARK: - plannedReplacement (guards against silently dropping a conversion)

    @Test
    func testPlannedReplacementReturnsChangedText() {
        #expect(
            TextReplacer.plannedReplacement(in: "main: e,рал", start: 6, length: 5, replacement: "убрал")
                == "main: убрал")
    }

    @Test
    func testPlannedReplacementIsNilWhenIdentical() {
        // Converting yields the same text -> nothing to apply.
        #expect(
            TextReplacer.plannedReplacement(in: "123 456", start: 0, length: 3, replacement: "123") == nil)
    }

    @Test
    func testPlannedReplacementIsNilForUnalignedRange() {
        // A range that splits a surrogate pair makes replaceToken a no-op; this
        // must read as "no conversion" (nil), NOT as "already applied", so the
        // cascade falls through to the paste path instead of dropping it.
        #expect(
            TextReplacer.plannedReplacement(in: "a👍b", start: 1, length: 1, replacement: "X") == nil)
    }

    @Test
    func testPlannedReplacementOutOfRangeIsNil() {
        #expect(
            TextReplacer.plannedReplacement(in: "hi", start: 10, length: 1, replacement: "x") == nil)
    }
}
