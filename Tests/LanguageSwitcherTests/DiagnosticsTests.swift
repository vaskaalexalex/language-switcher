import Foundation
import Testing
@testable import LanguageSwitcher

/// The diagnostics export keeps only the last N conversions so a bug report is
/// focused on what just happened, not weeks of history.
@Suite
struct DiagnosticsTests {
    /// A log with `n` conversions plus interleaved noise (launches, ignored
    /// Option taps) between them.
    private func makeLog(conversations n: Int) -> String {
        var out: [String] = ["=== launching (pid=1) ===", "Event tap created"]
        for i in 1...n {
            out.append("Option up: fire=false")
            out.append("Trigger fired (frontmost=app\(i))")
            out.append("Converting: \"src\(i)\" -> \"dst\(i)\"")
            out.append("SUMMARY app=app\(i) \"src\(i)\" -> \"dst\(i)\" ok=true")
        }
        return out.joined(separator: "\n")
    }

    @Test
    func testKeepsOnlyLastFiveConversions() {
        let log = makeLog(conversations: 8)
        let recent = Diagnostics.lastConversations(in: log, count: 5)
        // The oldest three conversions are dropped...
        for dropped in 1...3 {
            #expect(!recent.contains("frontmost=app\(dropped)"))
        }
        // ...the last five are kept, in order.
        for kept in 4...8 {
            #expect(recent.contains("Trigger fired (frontmost=app\(kept))"))
            #expect(recent.contains("SUMMARY app=app\(kept)"))
        }
        // The result starts exactly at the 4th conversion's trigger line.
        #expect(recent.hasPrefix("Trigger fired (frontmost=app4)"))
    }

    @Test
    func testReturnsWholeLogWhenFewerThanLimit() {
        let log = makeLog(conversations: 3)
        let recent = Diagnostics.lastConversations(in: log, count: 5)
        #expect(recent == log)
        #expect(recent.contains("=== launching"))
    }

    @Test
    func testHandlesExactlyLimit() {
        let log = makeLog(conversations: 5)
        // Exactly 5 (not > 5) -> whole log retained.
        #expect(Diagnostics.lastConversations(in: log, count: 5) == log)
    }

    @Test
    func testNoConversationsReturnsWholeLog() {
        let log = "=== launching ===\nEvent tap created\nOption up: fire=false"
        #expect(Diagnostics.lastConversations(in: log, count: 5) == log)
    }

    @Test
    func testZeroCountReturnsEmpty() {
        #expect(Diagnostics.lastConversations(in: makeLog(conversations: 3), count: 0) == "")
    }
}
