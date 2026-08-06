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

    // MARK: - clipboardHoldsFieldText (the app rewrote our copy)

    @Test
    func testPageAppendedAttributionIsNotTheSelection() {
        // The reported case: on livelib.ru a `copy` handler appends its own
        // attribution to every clipboard write, so the pipeline's Cmd+C on a
        // 4-char field came back with 91 chars. Converting that blob left the
        // user's "туц" untouched (mixed script keeps Cyrillic) — "туц" never
        // became "new".
        let copied = "туц\nПодробнее на livelib.ru:\n"
            + "https://www.livelib.ru/selection/10353-novye-strannyenew-weird"
        #expect(!TextReplacer.clipboardHoldsFieldText(copied, fullText: "туц "))
        // Same handler with nothing selected: pure attribution, no field text.
        #expect(
            !TextReplacer.clipboardHoldsFieldText(
                "\nПодробнее на livelib.ru:\nhttps://www.livelib.ru/selection/10353",
                fullText: "туц "))
    }

    @Test
    func testGenuineSelectionComesOutOfTheField() {
        #expect(TextReplacer.clipboardHoldsFieldText("туц", fullText: "туц "))
        #expect(TextReplacer.clipboardHoldsFieldText("world", fullText: "hello world"))
        #expect(TextReplacer.clipboardHoldsFieldText("hello world", fullText: "hello world"))
    }

    @Test
    func testCrlfClipboardStillMatchesLfFieldValue() {
        // Web fields hand back CRLF while AXValue reports LF — a genuine
        // multi-line selection must not be read as foreign text.
        #expect(TextReplacer.clipboardHoldsFieldText("foo\r\nbar", fullText: "foo\nbar baz"))
        #expect(TextReplacer.clipboardHoldsFieldText("foo\rbar", fullText: "foo\nbar"))
    }

    @Test
    func testNoEvidenceDoesNotRejectTheClipboard() {
        // Nothing to compare against (unreadable/empty AXValue, empty copy) —
        // the guard must stay out of the way instead of dropping the text.
        #expect(TextReplacer.clipboardHoldsFieldText("туц", fullText: ""))
        #expect(TextReplacer.clipboardHoldsFieldText("", fullText: "туц "))
    }

    // MARK: - pasteSelectionSource (what the pipeline converts, and when it refuses)

    private static let livelibCopy = "туц\nПодробнее на livelib.ru:\n"
        + "https://www.livelib.ru/selection/10353-novye-strannyenew-weird"

    @Test
    func testRewrittenCopyFallsBackToTheAXSlice() {
        #expect(
            TextReplacer.pasteSelectionSource(
                copied: Self.livelibCopy,
                axFullText: "туц ",
                axSlice: "туц",
                isForcePaste: false
            ) == .axSlice("туц"))
    }

    @Test
    func testUntouchedCopyIsConvertedAsIs() {
        #expect(
            TextReplacer.pasteSelectionSource(
                copied: "туц",
                axFullText: "туц ",
                axSlice: "туц",
                isForcePaste: false
            ) == .clipboard)
    }

    @Test
    func testTerminalKeepsTheClipboardAsTheOnlyTruth() {
        // A terminal's AXValue is a stale scrollback: the prompt line the user
        // just typed need not be in it, so it may not veto the clipboard.
        #expect(
            TextReplacer.pasteSelectionSource(
                copied: "ghbdtn",
                axFullText: "$ ls\ntotal 0\n$ ",
                axSlice: nil,
                isForcePaste: true
            ) == .clipboard)
    }

    @Test
    func testUnreadableFieldValueKeepsTheClipboard() {
        // Electron often exposes no AXValue at all — with nothing to compare
        // against the guard must stay out of the way.
        #expect(
            TextReplacer.pasteSelectionSource(
                copied: Self.livelibCopy,
                axFullText: nil,
                axSlice: nil,
                isForcePaste: false
            ) == .clipboard)
    }

    @Test
    func testEmptyCopyIsRefused() {
        #expect(
            TextReplacer.pasteSelectionSource(
                copied: "",
                axFullText: "туц ",
                axSlice: "туц",
                isForcePaste: false
            ) == .refuse)
    }

    @Test
    func testFullyDivergentSourcesAreRefusedNotGuessed() {
        // The AX slice must show up inside what the app copied — that is what
        // makes "the app appended its own text" a safe reading. When the two
        // sources share nothing, AX offsets are as suspect as the clipboard
        // (the reason rich text avoids AX writes in the first place), so beep
        // instead of pasting a guess over the user's selection.
        #expect(
            TextReplacer.pasteSelectionSource(
                copied: "Подробнее на livelib.ru",
                axFullText: "туц ",
                axSlice: "туц",
                isForcePaste: false
            ) == .refuse)
        #expect(
            TextReplacer.pasteSelectionSource(
                copied: Self.livelibCopy,
                axFullText: "туц ",
                axSlice: nil,
                isForcePaste: false
            ) == .refuse)
    }

    // MARK: - synthSelectionMatchesTarget (never paste into an unverified caret)

    @Test
    func testCaretAtStartSelectedNothing() {
        // Trigger 3 of the report: caret at 0, so ⇧←×3 selects nothing. Pasting
        // here inserts into the user's text ("newтуц ") instead of replacing.
        #expect(
            !TextReplacer.synthSelectionMatchesTarget(
                CFRange(location: 0, length: 0), start: 0, length: 3))
    }

    @Test
    func testSelectionOfRightLengthAtWrongOffsetIsRejected() {
        // Caret at the end of "туц ": ⇧←×3 spans "уц ", not the token "туц".
        // Pasting on the length alone would produce "тnew".
        #expect(
            !TextReplacer.synthSelectionMatchesTarget(
                CFRange(location: 1, length: 3), start: 0, length: 3))
    }

    @Test
    func testUnreadableRangeIsNotEvidence() {
        #expect(!TextReplacer.synthSelectionMatchesTarget(nil, start: 0, length: 3))
    }

    @Test
    func testExactTargetRangeIsAccepted() {
        #expect(
            TextReplacer.synthSelectionMatchesTarget(
                CFRange(location: 0, length: 3), start: 0, length: 3))
        #expect(
            TextReplacer.synthSelectionMatchesTarget(
                CFRange(location: 6, length: 5), start: 6, length: 5))
    }

    // MARK: - shouldRetryPaste (the app read a pasteboard that was no longer ours)

    @Test
    func testRetryWhenOurTextWasOverwrittenAndTheFieldIsUntouched() {
        // A page `copy` handler hands its data to the browser process
        // asynchronously, so the browser's own clipboard write can land after
        // we put the conversion on the pasteboard — the app then pastes the
        // page's text instead of ours and the field looks untouched.
        #expect(TextReplacer.shouldRetryPaste(clipboardIntact: false, fieldUnchanged: true))
    }

    @Test
    func testNoRetryOnceTheFieldChanged() {
        // Something landed. A second paste would duplicate the edit, and two
        // separate edits can't be undone with a single Cmd+Z.
        #expect(!TextReplacer.shouldRetryPaste(clipboardIntact: false, fieldUnchanged: false))
    }

    @Test
    func testNoRetryWhenOurTextSurvivedOnThePasteboard() {
        // The app had the conversion available and still didn't take it —
        // offering the same pasteboard again changes nothing.
        #expect(!TextReplacer.shouldRetryPaste(clipboardIntact: true, fieldUnchanged: true))
        #expect(!TextReplacer.shouldRetryPaste(clipboardIntact: true, fieldUnchanged: false))
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
