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
}
