import Testing
@testable import LanguageSwitcher

@Suite
struct PreferencesTests {
    @Test
    func testHostileTerminalsAddedToEmptyBlacklist() {
        let result = Preferences.ensuringHostileTerminals(in: [])
        #expect(result.contains("dev.warp.Warp-Stable"))
        #expect(result.contains("dev.warp.Warp-Beta"))
    }

    @Test
    func testExistingEntriesPreservedAndMerged() {
        let result = Preferences.ensuringHostileTerminals(in: ["com.apple.Terminal", "com.googlecode.iterm2"])
        #expect(result.contains("com.apple.Terminal"))
        #expect(result.contains("com.googlecode.iterm2"))
        #expect(result.contains("dev.warp.Warp-Stable"))
        // Sorted output.
        #expect(result == result.sorted())
    }

    @Test
    func testIdempotentNoDuplicates() {
        let once = Preferences.ensuringHostileTerminals(in: [])
        let twice = Preferences.ensuringHostileTerminals(in: once)
        #expect(once == twice)
        #expect(Set(twice).count == twice.count) // no dupes
    }
}
