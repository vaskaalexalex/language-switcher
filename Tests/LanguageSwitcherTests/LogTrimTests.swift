import Foundation
import Testing
@testable import LanguageSwitcher

/// The diagnostics log is append-only; `trimmedTail` bounds it so the export
/// surfaces recent activity instead of weeks-old history.
@Suite
struct LogTrimTests {
    @Test
    func testNoTrimWhenUnderBudget() {
        let data = Data("line1\nline2\n".utf8)
        #expect(Log.trimmedTail(data, keepBytes: 1000) == data)
    }

    @Test
    func testTrimsToLastBytesAndDropsPartialFirstLine() {
        let data = Data("aaaa\nbbbb\ncccc\ndddd\n".utf8) // 20 bytes
        // Keep ~12 bytes -> suffix lands mid-"bbbb"; the partial line is dropped
        // so the result starts on a clean entry.
        let kept = Log.trimmedTail(data, keepBytes: 12)
        let text = String(decoding: kept, as: UTF8.self)
        #expect(!text.contains("aaaa"))
        #expect(text.hasSuffix("dddd\n"))
        // Every retained line is whole (no leading partial fragment).
        for line in text.split(separator: "\n") {
            #expect(["aaaa", "bbbb", "cccc", "dddd"].contains(String(line)))
        }
    }

    @Test
    func testTrimKeepsRecentTail() {
        let data = Data("old\nrecent\n".utf8)
        let kept = Log.trimmedTail(data, keepBytes: 7)
        #expect(String(decoding: kept, as: UTF8.self) == "recent\n")
    }
}
