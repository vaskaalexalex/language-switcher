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

    // MARK: - logSnippet (the ambiguous branch must show the real field value)

    @Test
    func testShortValueIsQuotedInFull() {
        #expect(TextReplacer.logSnippet("О2ндфл2ylak") == "\"О2ндфл2ylak\"")
        #expect(TextReplacer.logSnippet("") == "\"\"")
        #expect(TextReplacer.logSnippet(nil) == "nil")
    }

    @Test
    func testLongValueIsTruncatedNotDropped() {
        let long = String(repeating: "я", count: 400)
        let snippet = TextReplacer.logSnippet(long, limit: 10)
        #expect(snippet == "\"яяяяяяяяяя…\"")
    }

    // MARK: - fieldWindow (the log's stand-in for looking at the screen)

    @Test
    func testCaretIsMarkedAndSurroundingTextKept() {
        let field = "Отправляю Вам справку 2ylak"
        #expect(TextReplacer.fieldWindow(field, caret: 27) == "\"Отправляю Вам справку 2ylak|\"")
        #expect(TextReplacer.fieldWindow(field, caret: 22, window: 6) == "\"…равку |2ylak\"")
    }

    @Test
    func testElidedSidesAreMarked() {
        let field = "Отправляю Вам справку 2ylak"
        #expect(TextReplacer.fieldWindow(field, caret: 27, window: 10) == "\"…авку 2ylak|\"")
        // Nil caret means "end of field" — the corrupted Firefox value read
        // back after a write has no caret to report.
        #expect(TextReplacer.fieldWindow("О2ндфл2ylak", caret: nil) == "\"О2ндфл2ylak|\"")
    }

    @Test
    func testCaretInsideSurrogatePairDoesNotDuplicateTheGlyph() {
        // 👍 spans UTF-16 offsets 3...4; a caret reported at 4 must snap left,
        // not expand both halves of the window over the pair.
        #expect(TextReplacer.fieldWindow("hi 👍 there", caret: 4, window: 3) == "\"hi |👍 …\"")
        #expect(TextReplacer.fieldWindow("hi 👍 there", caret: 5, window: 3) == "\"… 👍| th…\"")
        #expect(TextReplacer.fieldWindow("e\u{0301}xy", caret: 1, window: 2) == "\"|é…\"")
    }

    @Test
    func testOutOfRangeCaretAndEmptyValueAreSafe() {
        #expect(TextReplacer.fieldWindow("abc", caret: 99) == "\"abc|\"")
        #expect(TextReplacer.fieldWindow("abc", caret: -5) == "\"|abc\"")
        #expect(TextReplacer.fieldWindow("", caret: 0) == "\"\"")
        #expect(TextReplacer.fieldWindow(nil, caret: 3) == "nil")
    }

    // MARK: - ConversionSummary (one line, no follow-up questions)

    @Test
    func testSummaryLineCarriesTheWholeDiagnosis() {
        var summary = TextReplacer.ConversionSummary()
        summary.app = "org.mozilla.firefox"
        summary.richText = true
        summary.role = "AXTextArea"
        summary.original = "2ylak"
        summary.converted = "2ндфл"
        summary.via = "pipeline-paste"
        summary.pastePath = true
        summary.outcome = .assumed
        summary.planned = "no"
        summary.post = "\"О2ндфл2ylak|\""

        #expect(
            summary.line
                == "SUMMARY app=org.mozilla.firefox electron=false forcePaste=false richText=true "
                + "role=AXTextArea valueSettable=false selection=false "
                + "\"2ylak\" -> \"2ндфл\" via=pipeline-paste pastePath=true ok=assumed "
                + "planned=no post=\"О2ндфл2ylak|\"")
    }

    @Test
    func testUnverifiedWriteIsNotReportedAsPlainSuccess() {
        // The regression this whole line exists for: an AX write nobody
        // confirmed must never read as an unqualified success.
        var summary = TextReplacer.ConversionSummary()
        summary.outcome = .assumed
        #expect(summary.line.contains("ok=assumed"))
        #expect(!summary.line.contains("ok=true"))
    }
}
