import AppKit
import ApplicationServices

final class TextReplacer {
    static let shared = TextReplacer()
    private init() {}

    private var isBusy = false

    /// Main entry point. Called from the hotkey handler on the main thread.
    func convertCurrentTextOrLastWord() {
        guard !isBusy else {
            Log.info("Busy, ignoring trigger")
            return
        }
        isBusy = true

        Task { @MainActor in
            defer { self.isBusy = false }
            await self.run()
        }
    }

    @MainActor
    private func run() async {
        let started = CACurrentMediaTime()
        let frontmost = NSWorkspace.shared.frontmostApplication
        Log.info("Trigger fired (frontmost=\(frontmost?.bundleIdentifier ?? "nil"))")
        let element = AccessibilityBridge.focusedElement()
        if element == nil {
            Log.info("No focused AX element")
        }

        let isElectron = FrontmostApp.isElectron(frontmost)
        let isForcePaste = FrontmostApp.isForcePasteApp(frontmost)
        var summary = ConversionSummary(
            app: frontmost?.bundleIdentifier ?? "nil",
            electron: isElectron,
            forcePaste: isForcePaste,
            role: element.flatMap {
                AccessibilityBridge.stringAttribute($0, kAXRoleAttribute as String)
            } ?? "nil",
            valueSettable: element.map {
                AccessibilityBridge.isAttributeSettable($0, kAXValueAttribute as String)
            } ?? false)

        if let element, AccessibilityBridge.isSecureField(element) {
            Log.info("Secure field, skipping")
            summary.outcome = .skipped
            Log.info(summary.line)
            NSSound.beep()
            return
        }

        // A rich-text element (contenteditable, `AXAttributedStringForRange`)
        // is hostile to *both* AX writes, not just the AXValue one. In Firefox
        // + Gmail the `kAXSelectedTextAttribute` write landed on a span of the
        // browser's own choosing — "Отправляю Вам справку 2ylak" became
        // "О2ндфл2ylak" — while AXValue kept reporting the pre-write text, so
        // neither the write verification nor the duplicate guard could see the
        // damage and the conversion was still reported ok. Rich text therefore
        // goes through the same synthetic-selection + paste pipeline as
        // Electron and the AX-write-hostile terminals (Warp, Ghostty, …): that
        // path verifies the selection by copying it and comparing the real
        // content, so it never trusts an AX offset.
        let isRichText = element.map(AccessibilityBridge.supportsAttributedText) ?? false
        summary.richText = isRichText
        if isRichText {
            Log.info("Rich-text element detected, AX writes disabled")
        }
        let usesPastePipeline = isElectron || isForcePaste || isRichText
        if usesPastePipeline {
            Log.info(
                "Paste pipeline for \(frontmost?.bundleIdentifier ?? "nil") "
                + "(electron=\(isElectron) forcePaste=\(isForcePaste) richText=\(isRichText))")
        }

        // 1) Does the AX layer see an existing selection?
        let axRange: CFRange? = element.flatMap {
            AccessibilityBridge.rangeAttribute($0, kAXSelectedTextRangeAttribute as String)
        }
        let hasSelection = (axRange?.length ?? 0) > 0
        summary.selection = hasSelection
        var selectionState: SelectionState = hasSelection ? .axNative : .unknown
        if let r = axRange {
            Log.info("AX range loc=\(r.location) len=\(r.length)")
        }

        // 2) Pre-compute replacement range from AXValue + caret when there is no
        //    explicit selection (last token before caret).
        let caretPosition = axRange.map { $0.location + $0.length }
        var axTarget: TokenTarget?
        var axFullText: String?
        if let element {
            axFullText = AccessibilityBridge.stringAttribute(element, kAXValueAttribute as String)
            // In a terminal (force-paste) the AXValue is the whole scrollback
            // buffer and the "last token" is stale output, not the editable
            // prompt — so don't anchor on it. Leaving axTarget nil routes the
            // conversion to the pure synthetic-selection path, which selects the
            // last word from the real caret (and beeps if the prompt is empty).
            if !hasSelection && !isForcePaste {
                axTarget = axFullText.flatMap { Self.computeTokenTarget(in: $0, caretHint: caretPosition) }
                    .map { TokenTarget(start: $0.start, length: $0.length, snippet: $0.snippet) }
            }
        }
        if let element {
            // The pre-write state of the field, in one line. Without it a bug
            // report can only say "the text came out wrong" — with it the log
            // shows what the caret sat in and whether AX writes were even
            // permitted, which is what separates a bad target range from a
            // hostile app.
            Log.info(
                "Field role=\(summary.role) "
                + "subrole=\(AccessibilityBridge.stringAttribute(element, kAXSubroleAttribute as String) ?? "nil") "
                + "richText=\(isRichText) "
                + "settable(value=\(summary.valueSettable) "
                + "selText=\(AccessibilityBridge.isAttributeSettable(element, kAXSelectedTextAttribute as String))) "
                + "len=\(axFullText.map { ($0 as NSString).length }.map(String.init) ?? "nil") "
                + "caret=\(caretPosition.map(String.init) ?? "nil") "
                + "text=\(Self.fieldWindow(axFullText, caret: caretPosition))")
        }

        if let t = axTarget {
            Log.info("AX token target: range=(\(t.start),\(t.length)) snippet=\(t.snippet.debugDescription)")
        }

        // 3) Resolve text to convert.
        var selected = ""
        if hasSelection {
            if usesPastePipeline {
                let copied = await clipboardRead()
                let axSlice = axFullText.flatMap { full in
                    axRange.flatMap { Self.snippet(from: full, start: $0.location, length: $0.length) }
                }
                switch Self.pasteSelectionSource(
                    copied: copied,
                    axFullText: axFullText,
                    axSlice: axSlice,
                    isForcePaste: isForcePaste
                ) {
                case .clipboard:
                    selected = copied
                    if copied.isEmpty {
                        Log.info("Paste-pipeline selection clipboard empty; refusing AX selected text fallback")
                    } else {
                        Log.info("Paste-pipeline existing selection read via clipboard (\(copied.count) chars)")
                    }
                case .axSlice(let slice):
                    // The app rewrote our copy (a page `copy` handler appending
                    // its own attribution). Convert what AX says is selected
                    // instead of the injected text.
                    selected = slice
                    Log.info(
                        "Clipboard selection (\(copied.count) chars) is not part of the field value "
                        + "(\(axFullText?.count ?? 0) chars); the app rewrote the copy. "
                        + "Falling back to the AX selection slice (\(slice.count) chars)")
                case .refuse:
                    selected = ""
                    Log.info(
                        "Clipboard selection \(Self.logSnippet(copied)) and the AX slice "
                        + "\(Self.logSnippet(axSlice)) share nothing; refusing to convert either")
                }
            } else {
                selected = axSelectedText(element)
                if selected.isEmpty { selected = await clipboardRead() }
            }
        } else if let t = axTarget, let element {
            // Electron/Cursor: read the token straight from AXValue — no word-select needed.
            if let full = axFullText, let snippet = Self.snippet(from: full, start: t.start, length: t.length) {
                selected = snippet
                Log.info("Using AX value slice (\(snippet.count) chars)")
            }

            if usesPastePipeline {
                if await synthSelectAndVerify(expected: t.snippet) {
                    selectionState = .synth(length: t.length)
                    selected = t.snippet
                    Log.info("Synth selection verified (\(t.length) chars match AX snippet)")
                } else {
                    let realSelection = await clipboardRead()
                    let rewrittenCopy = !realSelection.isEmpty && !isForcePaste
                        && (axFullText.map { !$0.isEmpty && !Self.clipboardHoldsFieldText(realSelection, fullText: $0) } ?? false)
                    if rewrittenCopy {
                        // Same rewritten clipboard as above, but here the copy
                        // was the *only* evidence that ⇧← selected anything.
                        // Ask AX for the range instead of assuming the burst
                        // worked: growing a selection off text that isn't in
                        // the field walks over the user's words, and pasting on
                        // faith inserts into them.
                        let synthRange = AccessibilityBridge.rangeAttribute(
                            element, kAXSelectedTextRangeAttribute as String)
                        if Self.synthSelectionMatchesTarget(synthRange, start: t.start, length: t.length) {
                            selectionState = .synth(length: t.length)
                            selected = t.snippet
                            Log.info(
                                "Synth verification copy (\(realSelection.count) chars) was rewritten by the app; "
                                + "AX confirms the selection is the target (\(t.start),\(t.length))")
                        } else {
                            selected = ""
                            Log.info(
                                "Synth verification copy (\(realSelection.count) chars) was rewritten by the app and "
                                + "AX reports selection \(Self.rangeDescription(synthRange)) instead of "
                                + "(\(t.start),\(t.length)); refusing to paste into an unverified selection")
                        }
                    } else if !realSelection.isEmpty {
                        Log.info("Synth selection mismatch; growing real selection from \(realSelection.debugDescription)")
                        let grown = await growSelectionLeftToWhitespace(initial: realSelection)
                        selectionState = .synth(length: (grown as NSString).length)
                        selected = grown
                        if grown != realSelection {
                            Log.info("Grew paste-pipeline selection len \(realSelection.count) -> \(grown.count)")
                        } else {
                            Log.info("Paste-pipeline selection did not grow")
                        }
                    } else {
                        selected = ""
                        Log.info("Synth selection empty; refusing AX target snippet fallback")
                    }
                }
            } else {
                let newRange = CFRange(location: t.start, length: t.length)
                let axSet = AccessibilityBridge.setRangeAttribute(
                    element, kAXSelectedTextRangeAttribute as String, newRange)
                Log.info("AX set range=\(axSet)")

                if axSet {
                    let verified = await waitUntil(pollNanoseconds: 5_000_000, maxAttempts: 6) {
                        if let range = AccessibilityBridge.rangeAttribute(
                            element, kAXSelectedTextRangeAttribute as String
                        ) {
                            return range.location == t.start && range.length == t.length
                        }
                        let verify = self.axSelectedText(element)
                        return !verify.isEmpty && verify.count == t.length
                    }
                    if verified {
                        selectionState = .axNative
                        let axSelection = axSelectedText(element)
                        if selected.isEmpty { selected = axSelection }
                        Log.info("AX selection verified")
                    }
                }

                if selected.isEmpty {
                    Log.info("Selecting exact token via synth (\(Self.synthSelectionSteps(for: t.snippet)) graphemes)")
                    selected = await selectExactTokenViaSynth(graphemeCount: Self.synthSelectionSteps(for: t.snippet))
                    if selected.isEmpty {
                        selected = t.snippet
                        Log.info("Synth select empty; falling back to AX target snippet")
                    } else {
                        selectionState = .synth(length: t.length)
                    }
                }
            }
        } else {
            // Electron/terminal AX can't see a live selection (it reports
            // len=0 even with text highlighted). Probe the real selection with a
            // plain copy *before* touching it: if the user already selected
            // something, convert exactly that and never fire a word-select —
            // ⌥⇧← would extend their selection onto neighbouring words (the
            // "selected у2у, got Добавил у2у" bug).
            let probe = usesPastePipeline ? await clipboardRead() : ""
            if Self.isGenuineSelectionProbe(probe) {
                Log.info("Pre-existing selection via clipboard (\(probe.count) chars); converting as-is")
                selected = probe
                selectionState = .axNative
            } else {
                Log.info("No AX data, using synth + char-grow")
                KeyboardSynth.selectPreviousWord()
                let selectionElement = usesPastePipeline ? nil : element
                selected = await waitForSelection(
                    element: selectionElement,
                    viaClipboard: true,
                    maxAttempts: 5,
                    pollNanoseconds: 8_000_000)
                if !selected.isEmpty {
                    let grown = await growSelectionLeftToWhitespace(initial: selected)
                    if grown != selected {
                        Log.info("Grew selection len \(selected.count) -> \(grown.count)")
                        selected = grown
                    }
                }
            }
        }

        guard !selected.isEmpty else {
            Log.info("Nothing to convert, beep")
            // A silent trigger is a bug report too ("I tapped and nothing
            // happened"), so it gets the same one-line summary — with the field
            // snapshot above it, the log shows why nothing was picked up.
            summary.outcome = .empty
            summary.post = Self.fieldWindow(axFullText, caret: caretPosition, window: 32)
            Log.info(summary.line)
            NSSound.beep()
            return
        }

        let converted = LayoutConverter.convert(selected)
        Log.info("Converting: \(selected.debugDescription) -> \(converted.debugDescription)")

        var replacementTarget: TokenTarget?
        if hasSelection, let r = axRange, r.length > 0 {
            replacementTarget = Self.selectionTokenTarget(
                in: axFullText, range: r, fallbackSnippet: selected)
                .map { TokenTarget(start: $0.start, length: $0.length, snippet: $0.snippet) }
            if let t = replacementTarget {
                Log.info("AX selection target: range=(\(t.start),\(t.length)) snippet=\(t.snippet.debugDescription)")
            }
        } else {
            replacementTarget = axTarget
        }

        let expectedFullText: String? = {
            guard let t = replacementTarget, let full = axFullText else { return nil }
            return Self.plannedReplacement(
                in: full, start: t.start, length: t.length, replacement: converted)
        }()

        summary.original = selected
        summary.converted = converted

        var replacementSucceeded = false
        var usedPastePath = false

        if usesPastePipeline {
            Log.info("Paste pipeline: replacing real selection via paste")
            // No polling verification here: these apps' AXValue lags or lies,
            // so polling only adds ~200 ms to every conversion. The single
            // post-settle read inside `pasteReplacement` is free and still
            // upgrades the outcome to `verified` when AX does tell the truth.
            let verified = await pasteReplacement(
                converted,
                element: element,
                expectedFullText: expectedFullText,
                settleNanoseconds: 150_000_000,
                pollForVerification: false)
            replacementSucceeded = true
            usedPastePath = true
            summary.via = "pipeline-paste"
            summary.outcome = verified ? .verified : .assumed
        }

        if !replacementSucceeded, let element, !isRichText, let t = replacementTarget, let full = axFullText {
            replacementSucceeded = await tryAXValueReplacement(
                element: element, fullText: full, target: t, converted: converted)
            if replacementSucceeded {
                summary.via = "ax-value"
                summary.outcome = .verified
            }
        }

        if !replacementSucceeded, let element {
            if selectionState.needsSyntheticSelection, let t = replacementTarget {
                Log.info("Ensuring selection before AX/paste replacement")
                let synthSelection = await selectExactTokenViaSynth(graphemeCount: Self.synthSelectionSteps(for: t.snippet))
                if !synthSelection.isEmpty {
                    selectionState = .synth(length: t.length)
                }
            }
            replacementSucceeded = await tryAXReplacement(
                element: element,
                converted: converted,
                expectedFullText: expectedFullText)
            if replacementSucceeded {
                summary.via = "ax-selected-text"
                summary.outcome = .verified
            }
        }

        // Idempotency guard — the core fix for the "converted text is
        // duplicated, can't be undone with Cmd+Z" bug. An AX write above can
        // physically land even when its own verification timed out (lagging
        // AXValue). Re-read the value before pasting: if the conversion is
        // already present, pasting would insert a second copy, and because the
        // AX write and the paste are separate edits a single Cmd+Z can't undo
        // it. We only get here when both AX strategies reported failure, so the
        // only writer that could have changed the field is us — hence an
        // unexpected change (`.ambiguous`) is also treated as "don't paste
        // again", trading a rare wrong-but-single result for never duplicating.
        if !replacementSucceeded, let element, let expectedFullText {
            let applied = await waitUntil(pollNanoseconds: 8_000_000, maxAttempts: 8) {
                AccessibilityBridge.stringAttribute(element, kAXValueAttribute as String) == expectedFullText
            }
            if applied {
                Log.info("AX write already applied; skipping paste to avoid duplicate")
                replacementSucceeded = true
                summary.via = "ax-late-verify"
                summary.outcome = .verified
            } else {
                let current = AccessibilityBridge.stringAttribute(element, kAXValueAttribute as String)
                if Self.classifyAXWrite(
                    preValue: axFullText,
                    currentValue: current,
                    expectedFullText: expectedFullText
                ) == .ambiguous {
                    // Log what the field actually holds: this branch suppresses
                    // the paste and reports success, so without the observed
                    // value a mangled field looks like a clean conversion.
                    Log.info(
                        "Field changed after AX write; skipping paste to avoid duplicate "
                        + "(now=\(Self.logSnippet(current)) expected=\(Self.logSnippet(expectedFullText)))")
                    replacementSucceeded = true
                    summary.via = "ax-ambiguous"
                    summary.outcome = .assumed
                }
            }
        }

        if !replacementSucceeded {
            if selectionState.needsSyntheticSelection, let t = replacementTarget {
                let synthSelection = await selectExactTokenViaSynth(graphemeCount: Self.synthSelectionSteps(for: t.snippet))
                if !synthSelection.isEmpty {
                    selectionState = .synth(length: t.length)
                }
            }
            let verified = await pasteReplacement(
                converted,
                element: element,
                expectedFullText: expectedFullText,
                settleNanoseconds: 60_000_000,
                pollForVerification: true)
            replacementSucceeded = true
            usedPastePath = true
            summary.via = "paste"
            summary.outcome = verified ? .verified : .assumed
        }

        if replacementSucceeded && !usedPastePath {
            await positionCaretAfterReplacement(
                element: element, target: replacementTarget, converted: converted)
        }

        if Preferences.shared.switchKeyboardLayout {
            InputSource.switchToMatch(converted)
        }

        // What the field holds now, read once after every strategy has run.
        // This is the only evidence that distinguishes a clean conversion from
        // a mangled field when the app's own write verification can't be
        // trusted — `planned=no` is the signature of the Firefox rich-text
        // corruption and needs no follow-up question to the user.
        let postValue = element.flatMap {
            AccessibilityBridge.stringAttribute($0, kAXValueAttribute as String)
        }
        let postCaret = replacementTarget.map {
            Self.caretPositionAfterReplacement(start: $0.start, converted: converted)
        }
        summary.pastePath = usedPastePath
        summary.post = Self.fieldWindow(postValue, caret: postCaret, window: 32)
        summary.planned = {
            guard expectedFullText != nil else { return "unknown" }
            guard let postValue else { return "unreadable" }
            return postValue == expectedFullText ? "yes" : "no"
        }()
        if !replacementSucceeded {
            summary.outcome = .failed
        }

        let elapsed = (CACurrentMediaTime() - started) * 1000
        Log.info(String(format: "Conversion finished in %.0f ms", elapsed))

        // One grep-able line per conversion: what was there, what it became,
        // and how — this is the line a bug report should center on.
        Log.info(summary.line)
    }

    // MARK: - Target computation

    private struct TokenTarget {
        let start: Int
        let length: Int
        let snippet: String
    }

    /// How sure we are that the conversion reached the field.
    ///
    /// Deliberately three-valued: reporting a plain `ok=true` for a write we
    /// never confirmed is exactly what hid the Firefox rich-text corruption —
    /// the log claimed success while the field held mangled text.
    enum ReplacementOutcome: String {
        /// The field was read back and holds the converted text.
        case verified
        /// The mutation was issued and nothing contradicted it, but the app
        /// never confirmed it through AX (stale/lying AXValue).
        case assumed
        /// Every strategy reported failure.
        case failed
        /// Nothing to convert (empty field, caret with no word behind it).
        case empty
        /// Refused before touching anything (secure field).
        case skipped
    }

    /// The one grep-able line per trigger. Everything needed to diagnose a
    /// conversion without asking the user what they saw on screen: which app
    /// and element, which strategy ran, how confident the result is, and what
    /// the field actually held afterwards.
    struct ConversionSummary {
        var app: String = "nil"
        var electron = false
        var forcePaste = false
        var richText = false
        var role = "nil"
        var valueSettable = false
        var selection = false
        var original = ""
        var converted = ""
        var via = "none"
        var pastePath = false
        var outcome: ReplacementOutcome = .failed
        /// Whether the post-conversion field matches the text we planned to
        /// write: `yes`, `no` (the field holds something else — corruption or a
        /// foreign edit), `unreadable`, or `unknown` (no AX plan to compare).
        var planned = "unknown"
        var post = "nil"

        var line: String {
            "SUMMARY app=\(app) electron=\(electron) forcePaste=\(forcePaste) richText=\(richText) "
            + "role=\(role) valueSettable=\(valueSettable) selection=\(selection) "
            + "\(original.debugDescription) -> \(converted.debugDescription) "
            + "via=\(via) pastePath=\(pastePath) ok=\(outcome.rawValue) "
            + "planned=\(planned) post=\(post)"
        }
    }

    private enum SelectionState {
        case unknown
        case axNative
        case synth(length: Int)

        var needsSyntheticSelection: Bool {
            if case .unknown = self { return true }
            return false
        }
    }

    /// Inspects `AXValue` + the caret hint and returns the last whitespace-
    /// delimited token before the caret. Nil if AX doesn't expose the value.
    @MainActor
    private func computeLastTokenTarget(in element: AXUIElement, caretHint: Int?) -> TokenTarget? {
        guard let fullText = AccessibilityBridge.stringAttribute(element, kAXValueAttribute as String) else {
            return nil
        }
        guard let target = Self.computeTokenTarget(in: fullText, caretHint: caretHint) else { return nil }
        return TokenTarget(start: target.start, length: target.length, snippet: target.snippet)
    }

    static func snippet(from text: String, start: Int, length: Int) -> String? {
        let ns = text as NSString
        guard start >= 0, length > 0, start + length <= ns.length else { return nil }
        let range = NSRange(location: start, length: length)
        // Never slice through a surrogate pair / composed character sequence —
        // that yields mojibake. If the range isn't grapheme-aligned, refuse.
        guard ns.rangeOfComposedCharacterSequences(for: range) == range else { return nil }
        return ns.substring(with: range)
    }

    /// Explicit AX selection range — not the last-token heuristic.
    static func selectionTokenTarget(
        in text: String?,
        range: CFRange,
        fallbackSnippet: String
    ) -> (start: Int, length: Int, snippet: String)? {
        guard range.location >= 0, range.length > 0 else { return nil }
        let selectedSnippet: String
        if let text, let slice = Self.snippet(from: text, start: range.location, length: range.length) {
            selectedSnippet = slice
        } else {
            selectedSnippet = fallbackSnippet
        }
        return (start: range.location, length: range.length, snippet: selectedSnippet)
    }

    static func replaceToken(in text: String, start: Int, length: Int, replacement: String) -> String {
        let ns = text as NSString
        guard start >= 0, length >= 0, start + length <= ns.length else { return text }
        let range = NSRange(location: start, length: length)
        // Refuse to splice across a surrogate pair / composed character
        // sequence; doing so would corrupt the surrounding glyph.
        if length > 0, ns.rangeOfComposedCharacterSequences(for: range) != range { return text }
        return ns.replacingCharacters(in: range, with: replacement)
    }

    /// The full text after replacing the target token, or `nil` when the
    /// replacement is a no-op — either because the converted text is identical
    /// or because `replaceToken` refused an unaligned (grapheme-splitting)
    /// range. Returning `nil` keeps the cascade from mistaking an unchanged
    /// write for a successful conversion: without this, a bad selection range
    /// makes the AX value write "verify" instantly against the original text
    /// and silently drops the conversion. `nil` instead routes to the paste
    /// path, which overwrites the real selection.
    static func plannedReplacement(
        in full: String, start: Int, length: Int, replacement: String
    ) -> String? {
        let result = replaceToken(in: full, start: start, length: length, replacement: replacement)
        return result == full ? nil : result
    }

    /// UTF-16 offset immediately after a replaced token.
    static func caretPositionAfterReplacement(start: Int, converted: String) -> Int {
        start + (converted as NSString).length
    }

    /// Result of inspecting the focused element's value after an AX write
    /// attempt — used to decide whether a *second* (duplicating) mutation is
    /// needed. See the paste guard in `run()`.
    enum AXWriteOutcome: Equatable {
        /// The field already holds the converted result — do nothing more.
        case applied
        /// The field is unchanged — another strategy may safely apply it.
        case notApplied
        /// The field changed but not to the expected value — applying again
        /// risks duplicating text, so the cascade should stop.
        case ambiguous
    }

    /// Pure classifier at the heart of the duplication fix.
    ///
    /// An AX write can land in the target app even when its own verification
    /// read times out (some apps expose a lagging `AXValue`). If the cascade
    /// then pastes the conversion again the user gets a duplicate that a single
    /// Cmd+Z can't undo, because the AX write and the paste are separate edits.
    /// Given the value before any write (`preValue`), the value observed now
    /// (`currentValue`), and the expected post-conversion value, decide whether
    /// a prior write already produced (or partially produced) the result so the
    /// caller can suppress the second mutation.
    static func classifyAXWrite(
        preValue: String?,
        currentValue: String?,
        expectedFullText: String?
    ) -> AXWriteOutcome {
        guard let expectedFullText else { return .notApplied }
        guard let currentValue else { return .notApplied }
        if currentValue == expectedFullText { return .applied }
        if let preValue, currentValue != preValue { return .ambiguous }
        return .notApplied
    }

    /// Could `copied` have come out of `fullText`?
    ///
    /// The paste pipeline reads the selection with a synthetic Cmd+C, but a web
    /// page owns the `copy` event and may rewrite the clipboard: livelib.ru
    /// appends its own "Подробнее на livelib.ru: <url>" attribution to every
    /// copy. That turned a 4-char field ("туц ") into a 91-char blob, and since
    /// the blob mixes scripts the converter kept the user's Cyrillic and only
    /// mangled the injected Latin — "туц" never became "new", and the multi-line
    /// paste that followed never landed in the single-line field.
    ///
    /// Text that isn't part of the field's own value is not this field's
    /// selection, whatever the app put on the pasteboard. Callers fall back to
    /// what AX reports instead of converting the foreign text.
    static func clipboardHoldsFieldText(_ copied: String, fullText: String) -> Bool {
        let selection = normalizedNewlines(copied)
        let field = normalizedNewlines(fullText)
        // No evidence either way (unreadable AXValue, empty copy) — stay out of
        // the way rather than drop text the caller has no replacement for.
        guard !selection.isEmpty, !field.isEmpty else { return true }
        return field.contains(selection)
    }

    /// What the paste pipeline should convert once it has copied the selection.
    enum PasteSelectionSource: Equatable {
        /// The copy is the field's own text — convert exactly that.
        case clipboard
        /// The app rewrote the copy; convert what AX reports as selected.
        case axSlice(String)
        /// The two sources disagree beyond repair — beep, don't guess.
        case refuse
    }

    /// Decides what the paste pipeline converts, given the copy it just made,
    /// the field's own value, and the AX slice for the selected range.
    ///
    /// Kept pure and separate from `run()` because every branch here is a
    /// decision about writing into the user's text: fall back too eagerly and a
    /// stale AX offset overwrites the wrong characters, fall back too late and a
    /// page's `copy` handler dictates what gets converted.
    ///
    /// - A terminal (`isForcePaste`) exposes a stale scrollback as `AXValue`; it
    ///   need not contain the prompt line the user just typed, so it may not
    ///   veto the clipboard. Same for an unreadable value.
    /// - The AX slice is trusted only when it shows up *inside* the copy, which
    ///   is what makes "the app appended its own text" the sound reading. When
    ///   the sources share nothing, AX offsets are as suspect as the clipboard —
    ///   this is the same distrust that keeps rich text off the AX write path.
    static func pasteSelectionSource(
        copied: String,
        axFullText: String?,
        axSlice: String?,
        isForcePaste: Bool
    ) -> PasteSelectionSource {
        guard !copied.isEmpty else { return .refuse }
        guard !isForcePaste, let full = axFullText, !full.isEmpty else { return .clipboard }
        if clipboardHoldsFieldText(copied, fullText: full) { return .clipboard }

        guard let slice = axSlice, !slice.isEmpty,
              normalizedNewlines(copied).contains(normalizedNewlines(slice))
        else { return .refuse }
        return .axSlice(slice)
    }

    /// Did the synthetic ⇧← burst land on exactly the token we mean to replace?
    ///
    /// The verification copy is worthless in an app that rewrites the clipboard,
    /// and assuming the burst worked is how a paste ends up inserting instead of
    /// replacing: a caret at the start of the field selects nothing (`new` lands
    /// in front of the text — "newтуц "), and a caret past the token selects a
    /// shifted span of the same length ("тnew"). An unreadable range is not
    /// evidence either — it means beep, not "probably fine".
    static func synthSelectionMatchesTarget(_ range: CFRange?, start: Int, length: Int) -> Bool {
        guard let range else { return false }
        return range.location == start && range.length == length
    }

    /// Should the paste be issued a second time?
    ///
    /// A browser hands a page's `copy` handler data to its own process
    /// asynchronously, so that write can land *after* we put the conversion on
    /// the pasteboard — the app then pastes the page's text instead of ours and
    /// the field is left looking untouched. Re-issuing is safe only while the
    /// field still holds its pre-paste value: once something landed, a second
    /// paste duplicates the edit, and two separate edits can't be undone with a
    /// single Cmd+Z. If our text was still on the pasteboard, the app simply
    /// didn't take it and offering it again changes nothing.
    static func shouldRetryPaste(clipboardIntact: Bool, fieldUnchanged: Bool) -> Bool {
        !clipboardIntact && fieldUnchanged
    }

    static func rangeDescription(_ range: CFRange?) -> String {
        guard let range else { return "nil" }
        return "(\(range.location),\(range.length))"
    }

    /// Web fields hand a selection back with CRLF while `AXValue` reports LF —
    /// compare on one form so a genuine multi-line selection isn't read as
    /// foreign text.
    private static func normalizedNewlines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Distinguishes a real user selection from an editor's empty-selection
    /// "copy line" behavior, for the case where AX can't expose the selection
    /// (Electron reports `loc=0 len=0` even with text highlighted). We probe the
    /// selection with a plain Cmd+C; but VSCode/Cursor copy the *whole current
    /// line* — trailing newline included — when nothing is selected, so a
    /// non-empty clipboard alone doesn't prove a selection exists. Treat the
    /// probe as genuine only when it has visible content and is not
    /// newline-terminated (the tell-tale of a whole-line copy).
    static func isGenuineSelectionProbe(_ copied: String) -> Bool {
        guard copied.contains(where: { !$0.isWhitespace }) else { return false }
        // `Character.isNewline` covers \n, \r and the \r\n grapheme (Swift folds
        // CRLF into one Character, so `hasSuffix("\n")` would miss it).
        if let last = copied.last, last.isNewline { return false }
        return true
    }

    /// Quotable, length-bounded form of an AX value for the log. AXValue can be
    /// a whole document, and the log file is size-capped, so long values are
    /// truncated instead of dropped — a corrupted field must stay visible.
    static func logSnippet(_ value: String?, limit: Int = 120) -> String {
        guard let value else { return "nil" }
        guard value.count > limit else { return value.debugDescription }
        return (String(value.prefix(limit)) + "…").debugDescription
    }

    /// The field around the caret, quoted, with `|` marking the caret position
    /// and `…` marking elided text. This is the log's substitute for looking at
    /// the user's screen: a whole document is useless in a bug report, but the
    /// window the conversion touches shows both what was there and what the
    /// write did to it. Offsets are UTF-16 (AX's own unit) and are snapped to
    /// grapheme boundaries so the excerpt is never mojibake.
    static func fieldWindow(_ value: String?, caret: Int?, window: Int = 40) -> String {
        guard let value else { return "nil" }
        let ns = value as NSString
        guard ns.length > 0 else { return "\"\"" }

        // Anchor both halves at the same grapheme-aligned caret. Aligning the
        // two ranges independently makes a caret *inside* a surrogate pair
        // expand each of them over the whole pair, and the excerpt then shows
        // the glyph twice — a log that invents text is worse than no log.
        let caretPosition = graphemeBoundary(ns, at: min(max(caret ?? ns.length, 0), ns.length))
        let headStart = graphemeBoundary(ns, at: max(0, caretPosition - window))
        let tailEnd = max(caretPosition, graphemeBoundary(ns, at: min(ns.length, caretPosition + window)))

        let head = ns.substring(with: NSRange(location: headStart, length: caretPosition - headStart))
        let tail = ns.substring(with: NSRange(location: caretPosition, length: tailEnd - caretPosition))
        let leadingEllipsis = headStart > 0 ? "…" : ""
        let trailingEllipsis = tailEnd < ns.length ? "…" : ""

        return (leadingEllipsis + head + "|" + tail + trailingEllipsis).debugDescription
    }

    /// The start of the composed character sequence containing `offset` — i.e.
    /// `offset` snapped left onto a grapheme boundary.
    private static func graphemeBoundary(_ ns: NSString, at offset: Int) -> Int {
        let clamped = min(max(offset, 0), ns.length)
        guard clamped > 0, clamped < ns.length else { return clamped }
        return ns.rangeOfComposedCharacterSequence(at: clamped).location
    }

    /// Number of caret-stop key presses (⇧←) needed to traverse `token`.
    /// The caret moves by grapheme cluster, not UTF-16 code unit, so synthetic
    /// selection must count graphemes. Driving the loop by `NSString.length`
    /// over-selects on emoji / combining marks and converts the wrong span.
    static func synthSelectionSteps(for token: String) -> Int {
        token.count
    }

    static func computeTokenTarget(in text: String, caretHint: Int?) -> (start: Int, length: Int, snippet: String)? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }

        let whitespace = CharacterSet.whitespacesAndNewlines

        var effectiveEnd = ns.length
        while effectiveEnd > 0 {
            let ch = ns.substring(with: NSRange(location: effectiveEnd - 1, length: 1))
            if let scalar = ch.unicodeScalars.first, whitespace.contains(scalar) {
                effectiveEnd -= 1
            } else {
                break
            }
        }
        guard effectiveEnd > 0 else { return nil }

        let rawCaret = caretHint ?? effectiveEnd
        if rawCaret > effectiveEnd {
            return tokenBeforeTrailingWhitespace(in: ns, rawCaret: rawCaret, effectiveEnd: effectiveEnd, whitespace: whitespace)
        }

        var caret = rawCaret
        if caret <= 0 || caret > ns.length { caret = effectiveEnd }
        if caret > effectiveEnd { caret = effectiveEnd }

        while caret > 0 {
            let prev = ns.substring(with: NSRange(location: caret - 1, length: 1))
            if let scalar = prev.unicodeScalars.first, whitespace.contains(scalar) {
                caret -= 1
            } else {
                break
            }
        }
        guard caret > 0 else { return nil }

        let start = scanBackToWhitespace(in: ns, from: caret, whitespace: whitespace)
        let length = caret - start
        guard length > 0 else { return nil }

        let snippet = ns.substring(with: NSRange(location: start, length: length))
        return (start: start, length: length, snippet: snippet)
    }

    /// Caret sits in trailing whitespace after the last non-whitespace character.
    /// Select the previous word only when it ends with a letter or digit; otherwise
    /// there is nothing to convert (e.g. cursor after `main: `).
    private static func tokenBeforeTrailingWhitespace(
        in ns: NSString,
        rawCaret: Int,
        effectiveEnd: Int,
        whitespace: CharacterSet
    ) -> (start: Int, length: Int, snippet: String)? {
        var wsStart = min(rawCaret, ns.length)
        while wsStart > effectiveEnd {
            let prev = ns.substring(with: NSRange(location: wsStart - 1, length: 1))
            if let scalar = prev.unicodeScalars.first, whitespace.contains(scalar) {
                wsStart -= 1
            } else {
                break
            }
        }

        guard wsStart == effectiveEnd, effectiveEnd > 0 else { return nil }

        let start = scanBackToWhitespace(in: ns, from: effectiveEnd, whitespace: whitespace)
        let length = effectiveEnd - start
        guard length > 0 else { return nil }

        let snippet = ns.substring(with: NSRange(location: start, length: length))

        // Accept a letter-bearing word even when it ends in punctuation (e.g.
        // "hello," / "привет;") so the common case matches what the in-caret
        // branch returns one character earlier — otherwise the Option-tap is a
        // silent no-op for a punctuated word followed by a space. Two
        // deliberate exclusions (these diverge from the in-caret branch, but
        // only on tokens LayoutConverter wouldn't meaningfully convert anyway):
        //   - a token with no letter (digits / punctuation only) — nothing to fix;
        //   - a "prefix:" marker ending in a colon (the git branch line
        //     "main: ") — there is no real word to convert.
        guard tokenContainsLetter(snippet), !snippet.hasSuffix(":") else { return nil }

        return (start: start, length: length, snippet: snippet)
    }

    private static func tokenContainsLetter(_ token: String) -> Bool {
        token.contains { $0.isLetter }
    }

    private static func scanBackToWhitespace(in ns: NSString, from caret: Int, whitespace: CharacterSet) -> Int {
        var start = caret
        while start > 0 {
            let prev = ns.substring(with: NSRange(location: start - 1, length: 1))
            if let scalar = prev.unicodeScalars.first, whitespace.contains(scalar) { break }
            start -= 1
        }
        return start
    }

    // MARK: - AX direct replacement

    @MainActor
    private func tryAXValueReplacement(
        element: AXUIElement,
        fullText: String,
        target: TokenTarget,
        converted: String
    ) async -> Bool {
        // Bail if the replacement is a no-op (identical text, or an unaligned
        // range `replaceToken` refused): writing the unchanged value would
        // "verify" instantly and silently drop the conversion. Let the paste
        // path handle it instead.
        guard let expected = Self.plannedReplacement(
            in: fullText, start: target.start, length: target.length, replacement: converted
        ) else {
            Log.info("AX value write skipped (replacement is a no-op for this range)")
            return false
        }

        guard AccessibilityBridge.setStringAttribute(
            element, kAXValueAttribute as String, expected
        ) else {
            Log.info("AX value write failed")
            return false
        }

        let ok = await waitUntil(pollNanoseconds: 8_000_000, maxAttempts: 25) {
            guard let current = AccessibilityBridge.stringAttribute(element, kAXValueAttribute as String) else {
                return false
            }
            return current == expected
        }
        Log.info("AX value write \(ok ? "verified" : "unverified")")
        return ok
    }

    @MainActor
    private func tryAXReplacement(
        element: AXUIElement,
        converted: String,
        expectedFullText: String?
    ) async -> Bool {
        // Without an expected full AX value, direct writes are side effects we
        // cannot verify. Let the paste path handle that case.
        guard let expectedFullText else {
            Log.info("AX direct write skipped (no expected AX value)")
            return false
        }

        // Read a baseline AXValue *before* mutating. Writing
        // kAXSelectedTextAttribute physically replaces the selected token; if
        // we can't read AXValue we can't tell whether it landed, and a blind,
        // unverifiable write here would be re-applied by the paste fallback and
        // duplicate the text. So bail before touching the field. (The old code
        // checked this guard *after* the write — the bug behind the duplicate.)
        guard let preValue = AccessibilityBridge.stringAttribute(
            element, kAXValueAttribute as String
        ) else {
            Log.info("AX direct write skipped (AXValue unreadable, can't verify)")
            return false
        }

        guard AccessibilityBridge.setStringAttribute(
            element, kAXSelectedTextAttribute as String, converted
        ) else {
            Log.info("AX direct write failed")
            return false
        }

        // Trust the write only once we observe AXValue become the expected
        // text. Some apps expose a lagging AXValue, so poll the same ~200ms
        // window the paste path uses rather than ~40ms — the tight window was
        // timing out on slow apps and forcing a duplicating paste.
        let ok = await waitUntil(pollNanoseconds: 8_000_000, maxAttempts: 25) {
            guard let current = AccessibilityBridge.stringAttribute(
                element, kAXValueAttribute as String
            ) else { return false }
            return current != preValue && current == expectedFullText
        }
        Log.info("AX direct write \(ok ? "verified" : "unverified")")
        return ok
    }

    // MARK: - Post-replacement caret

    @MainActor
    private func positionCaretAfterReplacement(
        element: AXUIElement?,
        target: TokenTarget?,
        converted: String
    ) async {
        guard let target, let element else { return }

        let expected = Self.caretPositionAfterReplacement(start: target.start, converted: converted)

        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
            let set = AccessibilityBridge.setRangeAttribute(
                element, kAXSelectedTextRangeAttribute as String,
                CFRange(location: expected, length: 0))
            if !set {
                Log.info("Caret AX set failed (attempt \(attempt + 1))")
                continue
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
            if caretMatches(element: element, expected: expected) {
                Log.info("Caret positioned via AX at \(expected)")
                return
            }
        }
        Log.info("Caret AX verify failed at expected=\(expected)")
    }

    private func caretMatches(element: AXUIElement, expected: Int) -> Bool {
        guard let range = AccessibilityBridge.rangeAttribute(
            element, kAXSelectedTextRangeAttribute as String
        ) else {
            return false
        }
        return range.length == 0 && range.location == expected
    }

    // MARK: - Adaptive waits

    @MainActor
    private func waitUntil(
        pollNanoseconds: UInt64 = 5_000_000,
        maxAttempts: Int = 20,
        condition: () -> Bool
    ) async -> Bool {
        if condition() { return true }
        for _ in 0..<maxAttempts {
            try? await Task.sleep(nanoseconds: pollNanoseconds)
            if condition() { return true }
        }
        return false
    }

    @MainActor
    private func waitForSelection(
        element: AXUIElement?,
        viaClipboard: Bool,
        maxAttempts: Int,
        pollNanoseconds: UInt64
    ) async -> String {
        for _ in 0..<maxAttempts {
            let axText = axSelectedText(element)
            if !axText.isEmpty { return axText }
            if viaClipboard {
                let pb = NSPasteboard.general
                pb.clearContents()
                let baseline = pb.changeCount
                KeyboardSynth.copy()
                try? await Task.sleep(nanoseconds: pollNanoseconds)
                if pb.changeCount != baseline,
                   let s = pb.string(forType: .string), !s.isEmpty {
                    return s
                }
            } else {
                try? await Task.sleep(nanoseconds: pollNanoseconds)
            }
        }
        return ""
    }

    // MARK: - Exact-length synthetic selection

    @MainActor
    private func synthSelectAndVerify(expected: String) async -> Bool {
        let steps = Self.synthSelectionSteps(for: expected)
        guard steps > 0 else { return false }

        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)
        defer { restorePasteboard(pb, items: saved) }

        for _ in 0..<steps {
            KeyboardSynth.extendSelectionLeftChar()
        }

        let copied = await copySelection(pb)
        return copied == expected
    }

    /// Select exactly `length` characters left of the caret using ⇧← bursts.
    /// Avoids ⌥⇧← word boundaries that split tokens like `e,рал` in Electron.
    @MainActor
    private func selectExactTokenViaSynth(graphemeCount: Int) async -> String {
        guard graphemeCount > 0 else { return "" }

        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)
        defer { restorePasteboard(pb, items: saved) }

        for _ in 0..<graphemeCount {
            KeyboardSynth.extendSelectionLeftChar()
        }

        return await waitForSelection(
            element: nil, viaClipboard: true, maxAttempts: 8, pollNanoseconds: 8_000_000)
    }

    @MainActor
    private func copySelection(_ pb: NSPasteboard) async -> String {
        pb.clearContents()
        let baseline = pb.changeCount
        KeyboardSynth.copy()
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 8_000_000)
            if pb.changeCount != baseline,
               let s = pb.string(forType: .string) {
                return s
            }
        }
        return ""
    }

    // MARK: - Char-by-char selection grow (universal fallback)

    @MainActor
    private func growSelectionLeftToWhitespace(initial: String) async -> String {
        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)
        defer { restorePasteboard(pb, items: saved) }

        var current = initial
        let whitespace = CharacterSet.whitespacesAndNewlines

        for _ in 0..<200 {
            KeyboardSynth.extendSelectionLeftChar()
            try? await Task.sleep(nanoseconds: 8_000_000)

            pb.clearContents()
            let baseline = pb.changeCount
            KeyboardSynth.copy()

            var extended: String? = nil
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 8_000_000)
                if pb.changeCount != baseline,
                   let s = pb.string(forType: .string) {
                    extended = s
                    break
                }
            }

            guard let new = extended, !new.isEmpty else { break }
            if new.count <= current.count { break }

            let addedCount = new.count - current.count
            let addedPrefix = String(new.prefix(addedCount))
            if addedPrefix.unicodeScalars.contains(where: { whitespace.contains($0) }) {
                KeyboardSynth.shrinkSelectionRightChar()
                try? await Task.sleep(nanoseconds: 8_000_000)
                break
            }
            current = new
        }
        return current
    }

    // MARK: - AX reads

    private func axSelectedText(_ element: AXUIElement?) -> String {
        guard let element = element else { return "" }
        return AccessibilityBridge.stringAttribute(element, kAXSelectedTextAttribute as String) ?? ""
    }

    // MARK: - Clipboard read (used when AX can't see the selection)

    @MainActor
    private func clipboardRead() async -> String {
        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)

        pb.clearContents()
        let baseline = pb.changeCount
        KeyboardSynth.copy()

        var result = ""
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 8_000_000)
            if pb.changeCount != baseline,
               let s = pb.string(forType: .string), !s.isEmpty {
                result = s
                break
            }
        }

        // Wait for the pasteboard to go quiet before handing it back. A page's
        // `copy` handler runs in the browser's renderer and its data reaches
        // the system pasteboard through another process, so the first change we
        // see can be followed by the real one milliseconds later. Returning at
        // the first change lets that late write land on top of whatever we put
        // on the pasteboard next — including the conversion we are about to
        // paste, which is how a correct conversion ends up never reaching the
        // field.
        if !result.isEmpty {
            var lastCount = pb.changeCount
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 8_000_000)
                guard pb.changeCount != lastCount else { continue }
                lastCount = pb.changeCount
                if let s = pb.string(forType: .string), !s.isEmpty, s != result {
                    Log.info("Pasteboard changed again after the copy (\(result.count) -> \(s.count) chars); taking the later write")
                    result = s
                }
            }
        }

        restorePasteboard(pb, items: saved)
        return result
    }

    // MARK: - Pasteboard write

    /// Pastes `text` over whatever is currently selected.
    ///
    /// - Parameters:
    ///   - settleNanoseconds: how long the converted text must stay on the
    ///     pasteboard before the user's clipboard is restored. Synthetic Cmd+V
    ///     is consumed asynchronously, so restoring too early lets the app
    ///     paste stale text; the polling path has already waited and needs
    ///     less.
    ///   - pollForVerification: poll AXValue until it matches the plan. Only
    ///     worth it where AXValue is trustworthy — on the paste pipeline
    ///     (Electron, rich text, terminals) it just burns ~200 ms before
    ///     failing anyway.
    /// - Returns: `true` only when AXValue was observed to hold
    ///   `expectedFullText`. `false` means *unverified*, not *failed*.
    @MainActor
    private func pasteReplacement(
        _ text: String,
        element: AXUIElement?,
        expectedFullText: String?,
        settleNanoseconds: UInt64,
        pollForVerification: Bool
    ) async -> Bool {
        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)
        let preValue = element.flatMap {
            AccessibilityBridge.stringAttribute($0, kAXValueAttribute as String)
        }

        var verified = false
        for attempt in 1...2 {
            pb.clearContents()
            pb.setString(text, forType: .string)
            let ourChangeCount = pb.changeCount

            let pasteStarted = CACurrentMediaTime()
            KeyboardSynth.paste()

            if pollForVerification, let element, let expectedFullText {
                verified = await waitUntil(pollNanoseconds: 8_000_000, maxAttempts: 25) {
                    guard let current = AccessibilityBridge.stringAttribute(
                        element, kAXValueAttribute as String
                    ) else { return false }
                    return current == expectedFullText
                }
                Log.info("Paste \(verified ? "verified" : "unverified")")
            }

            let elapsedNs = UInt64((CACurrentMediaTime() - pasteStarted) * 1_000_000_000)
            if elapsedNs < settleNanoseconds {
                try? await Task.sleep(nanoseconds: settleNanoseconds - elapsedNs)
            }

            // Whether the conversion was still on the pasteboard when the app
            // got around to reading it. This is the difference between "the app
            // ignored our paste" and "the app pasted something else because its
            // own clipboard write landed on top of ours" — without it both look
            // identical in the log.
            let clipboardIntact = pb.changeCount == ourChangeCount

            // One read after the settle, on every path: it costs nothing and
            // turns "we pasted and hoped" into evidence whenever the app's
            // AXValue does reflect the edit.
            guard !verified, let element, let expectedFullText else { break }
            let current = AccessibilityBridge.stringAttribute(element, kAXValueAttribute as String)
            verified = current == expectedFullText
            Log.info(
                verified
                    ? "Paste confirmed after settle"
                    : "Paste unconfirmed after settle (now=\(Self.logSnippet(current)) "
                        + "pasteboard=\(clipboardIntact ? "ours" : "overwritten by the app"))")
            if verified { break }

            guard attempt == 1,
                  Self.shouldRetryPaste(clipboardIntact: clipboardIntact, fieldUnchanged: current == preValue)
            else { break }
            Log.info("The app overwrote our pasteboard before reading it; re-issuing the paste once")
        }

        restorePasteboard(pb, items: saved)
        return verified
    }

    // MARK: - Pasteboard save/restore

    private struct PasteboardItem {
        let types: [NSPasteboard.PasteboardType]
        let data: [NSPasteboard.PasteboardType: Data]
    }

    private func savePasteboard(_ pb: NSPasteboard) -> [PasteboardItem] {
        guard let items = pb.pasteboardItems else { return [] }
        var out: [PasteboardItem] = []
        for item in items {
            var bag: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    bag[type] = data
                }
            }
            out.append(PasteboardItem(types: item.types, data: bag))
        }
        return out
    }

    private func restorePasteboard(_ pb: NSPasteboard, items: [PasteboardItem]) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let newItems: [NSPasteboardItem] = items.map { saved in
            let item = NSPasteboardItem()
            for type in saved.types {
                if let data = saved.data[type] {
                    item.setData(data, forType: type)
                }
            }
            return item
        }
        pb.writeObjects(newItems)
    }
}
