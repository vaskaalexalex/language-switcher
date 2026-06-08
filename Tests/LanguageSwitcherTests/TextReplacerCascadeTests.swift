import Foundation
import Testing
@testable import LanguageSwitcher

/// Covers the pure decision logic that guards the replacement cascade against
/// the "duplicated text / wrong span" bugs:
///   - `classifyAXWrite` decides whether a prior AX write already landed, so
///     the cascade never pastes a second (un-undoable) copy.
///   - `synthSelectionSteps` counts grapheme clusters, so synthetic ⇧←
///     selection spans exactly the token and not one code unit too many.
@Suite
struct TextReplacerCascadeTests {

    // MARK: - classifyAXWrite (duplication guard)

    @Test
    func testAppliedWhenCurrentEqualsExpected() {
        #expect(
            TextReplacer.classifyAXWrite(
                preValue: "main: e,рал",
                currentValue: "main: убрал",
                expectedFullText: "main: убрал"
            ) == .applied)
    }

    @Test
    func testAppliedEvenWhenPreValueUnknown() {
        // A lagging AXValue may not have been readable before the write, but if
        // it now reads the expected text the conversion is done — don't paste.
        #expect(
            TextReplacer.classifyAXWrite(
                preValue: nil,
                currentValue: "убрал",
                expectedFullText: "убрал"
            ) == .applied)
    }

    @Test
    func testNotAppliedWhenFieldUnchanged() {
        // Field still holds the original text -> no write landed -> safe to
        // apply the conversion via paste.
        #expect(
            TextReplacer.classifyAXWrite(
                preValue: "e,рал",
                currentValue: "e,рал",
                expectedFullText: "убрал"
            ) == .notApplied)
    }

    @Test
    func testAmbiguousWhenChangedButNotToExpected() {
        // The field changed (some write landed) but not to the expected value;
        // pasting now would compound the change into a duplicate, so the
        // cascade must stop rather than paste.
        #expect(
            TextReplacer.classifyAXWrite(
                preValue: "e,рал",
                currentValue: "убралX",
                expectedFullText: "убрал"
            ) == .ambiguous)
    }

    @Test
    func testNotAppliedWhenChangedButNoBaseline() {
        // Without a baseline we cannot prove the field changed because of our
        // write, so we treat it as not-applied (and the caller may paste).
        #expect(
            TextReplacer.classifyAXWrite(
                preValue: nil,
                currentValue: "something",
                expectedFullText: "убрал"
            ) == .notApplied)
    }

    @Test
    func testNotAppliedWhenCurrentUnreadable() {
        #expect(
            TextReplacer.classifyAXWrite(
                preValue: "e,рал",
                currentValue: nil,
                expectedFullText: "убрал"
            ) == .notApplied)
    }

    @Test
    func testNotAppliedWhenNoExpectedText() {
        #expect(
            TextReplacer.classifyAXWrite(
                preValue: "a",
                currentValue: "b",
                expectedFullText: nil
            ) == .notApplied)
    }

    // MARK: - synthSelectionSteps (correct word span)

    @Test
    func testAsciiStepsEqualLength() {
        #expect(TextReplacer.synthSelectionSteps(for: "hello") == 5)
        #expect(TextReplacer.synthSelectionSteps(for: "") == 0)
    }

    @Test
    func testCyrillicStepsCountGraphemesNotBytes() {
        #expect(TextReplacer.synthSelectionSteps(for: "убрал") == 5)
        #expect(TextReplacer.synthSelectionSteps(for: "привет,") == 7)
    }

    @Test
    func testEmojiCountsAsOneStepNotTwoCodeUnits() {
        // 👍 is a surrogate pair (NSString length 2) but a single caret stop.
        #expect(("👍" as NSString).length == 2)
        #expect(TextReplacer.synthSelectionSteps(for: "👍") == 1)
    }

    @Test
    func testCombiningMarkCountsAsOneStep() {
        // "é" decomposed = e + U+0301 (NSString length 2) but one grapheme.
        let decomposed = "e\u{0301}"
        #expect((decomposed as NSString).length == 2)
        #expect(TextReplacer.synthSelectionSteps(for: decomposed) == 1)
        #expect(TextReplacer.synthSelectionSteps(for: "caf\u{0301}e") == 4)
    }

    @Test
    func testFlagEmojiCountsAsOneStep() {
        // 🇷🇺 is two regional-indicator scalars (NSString length 4) = one grapheme.
        #expect(("🇷🇺" as NSString).length == 4)
        #expect(TextReplacer.synthSelectionSteps(for: "🇷🇺") == 1)
    }

    // MARK: - isGenuineSelectionProbe (don't extend a live Electron selection)

    @Test
    func testInlineSelectionIsGenuine() {
        // The reported case: AX can't see it, but the user really did select
        // "у2у" — converting it as-is must win over a word-select that would
        // grab "Добавил у2у".
        #expect(TextReplacer.isGenuineSelectionProbe("у2у"))
        #expect(TextReplacer.isGenuineSelectionProbe("Добавил у2у"))
        #expect(TextReplacer.isGenuineSelectionProbe("у2у "))
    }

    @Test
    func testEmptySelectionLineCopyIsNotGenuine() {
        // VSCode/Cursor copy the whole line (trailing newline) when nothing is
        // selected — must NOT be mistaken for a real selection.
        #expect(!TextReplacer.isGenuineSelectionProbe("Добавил у2у\n"))
        #expect(!TextReplacer.isGenuineSelectionProbe("kit \r\n"))
        #expect(!TextReplacer.isGenuineSelectionProbe("\n"))
    }

    @Test
    func testEmptyOrWhitespaceProbeIsNotGenuine() {
        // No selection (clipboard unchanged) or whitespace-only -> nothing to do.
        #expect(!TextReplacer.isGenuineSelectionProbe(""))
        #expect(!TextReplacer.isGenuineSelectionProbe("   "))
        #expect(!TextReplacer.isGenuineSelectionProbe("\t"))
    }
}
