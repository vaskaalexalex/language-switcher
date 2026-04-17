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
        let frontmost = NSWorkspace.shared.frontmostApplication
        Log.info("Trigger fired (frontmost=\(frontmost?.bundleIdentifier ?? "nil"))")

        let element = AccessibilityBridge.focusedElement()
        if element == nil {
            Log.info("No focused AX element")
        }

        if let element, AccessibilityBridge.isSecureField(element) {
            Log.info("Secure field, skipping")
            NSSound.beep()
            return
        }

        // 1) Does the AX layer see an existing selection?
        let axRange: CFRange? = element.flatMap {
            AccessibilityBridge.rangeAttribute($0, kAXSelectedTextRangeAttribute as String)
        }
        let hasSelection = (axRange?.length ?? 0) > 0
        if let r = axRange {
            Log.info("AX range loc=\(r.location) len=\(r.length)")
        }

        // 2) Pre-compute the target token from AXValue + caret, if AX can read
        //    them (works in Chrome, Electron, native text fields alike).
        let target = element.flatMap { computeLastTokenTarget(in: $0, caretHint: axRange?.location) }
        if let t = target {
            Log.info("AX target: range=(\(t.start),\(t.length)) snippet=\(t.snippet.debugDescription)")
        }

        // 3) If there is no existing selection, select the last token.
        var selected = ""
        if hasSelection {
            // User already has a selection — just read it.
            selected = axSelectedText(element)
            if selected.isEmpty { selected = await clipboardRead() }
        } else if let t = target, let element {
            // Fast AX write. Works in native text fields.
            let newRange = CFRange(location: t.start, length: t.length)
            let axSet = AccessibilityBridge.setRangeAttribute(
                element, kAXSelectedTextRangeAttribute as String, newRange)
            Log.info("AX set range=\(axSet)")

            if axSet {
                // Short verify. If AX reports the selection is really there we're done.
                try? await Task.sleep(nanoseconds: 25_000_000)
                let verify = axSelectedText(element)
                if !verify.isEmpty && verify.count == t.length {
                    selected = verify
                    Log.info("AX write verified (\(verify.count) chars)")
                }
            }

            // AX lied or refused (Chrome/Electron). Use the keyboard but we
            // already know how many characters we need, so it's one ⌥⇧← plus
            // a burst of ⇧← — no per-character clipboard polling. We also
            // verify that the AX snippet actually matches reality (Chrome
            // sometimes exposes placeholder text instead of the real value).
            if selected.isEmpty {
                Log.info("AX write ineffective, using synth with target=\(t.snippet.debugDescription)")
                selected = await selectTokenViaSynth(target: t)
            }
        } else {
            // No AX data at all. Fall back to the slow, universal path:
            // ⌥⇧← then grow char-by-char until whitespace.
            Log.info("No AX data, using synth + char-grow")
            KeyboardSynth.selectPreviousWord()
            try? await Task.sleep(nanoseconds: 60_000_000)
            selected = axSelectedText(element)
            if selected.isEmpty { selected = await clipboardRead() }
            if !selected.isEmpty {
                let grown = await growSelectionLeftToWhitespace(initial: selected)
                if grown != selected {
                    Log.info("Grew selection len \(selected.count) -> \(grown.count)")
                    selected = grown
                }
            }
        }

        guard !selected.isEmpty else {
            Log.info("Nothing to convert, beep")
            NSSound.beep()
            return
        }

        let converted = LayoutConverter.convert(selected)
        Log.info("Converting: \(selected.debugDescription) -> \(converted.debugDescription)")

        await pasteReplacement(converted)

        if Preferences.shared.switchKeyboardLayout {
            InputSource.switchToMatch(converted)
        }
    }

    // MARK: - Target computation

    private struct TokenTarget {
        let start: Int
        let length: Int
        let snippet: String
    }

    /// Inspects `AXValue` + the caret hint and returns the last whitespace-
    /// delimited token before the caret. Nil if AX doesn't expose the value.
    @MainActor
    private func computeLastTokenTarget(in element: AXUIElement, caretHint: Int?) -> TokenTarget? {
        guard let fullText = AccessibilityBridge.stringAttribute(element, kAXValueAttribute as String) else {
            return nil
        }
        let ns = fullText as NSString
        guard ns.length > 0 else { return nil }

        // Chrome/Electron commonly report caret=0 even when it's at the end.
        // Fall back to end-of-text in that case.
        var caret = caretHint ?? ns.length
        if caret <= 0 || caret > ns.length { caret = ns.length }

        let whitespace = CharacterSet.whitespacesAndNewlines
        var start = caret
        while start > 0 {
            let prev = ns.substring(with: NSRange(location: start - 1, length: 1))
            if let scalar = prev.unicodeScalars.first, whitespace.contains(scalar) { break }
            start -= 1
        }
        let length = caret - start
        guard length > 0 else { return nil }
        let snippet = ns.substring(with: NSRange(location: start, length: length))
        return TokenTarget(start: start, length: length, snippet: snippet)
    }

    // MARK: - Known-length synthetic selection (fast)

    /// Synthesizes ⌥⇧← (select prev word) then bursts ⇧← until the selection
    /// covers exactly `target.length` characters from the caret. Before the
    /// burst we sanity-check the AX snippet against the actual selection —
    /// if Chrome fed us a placeholder instead of the real value, the snippet
    /// won't match and we fall back to char-by-char grow.
    @MainActor
    private func selectTokenViaSynth(target: TokenTarget) async -> String {
        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)
        defer { restorePasteboard(pb, items: saved) }

        KeyboardSynth.selectPreviousWord()
        try? await Task.sleep(nanoseconds: 60_000_000)

        var current = await copySelection(pb)
        Log.info("synth initial selection len=\(current.count) value=\(current.debugDescription), target len=\(target.length)")

        // Sanity check: the initial word-left selection must be a suffix of
        // the AX snippet — otherwise AX reported a placeholder / stale value
        // and the target length is meaningless. Fall back to char-grow in
        // that case.
        let axTrustworthy = !current.isEmpty && target.snippet.hasSuffix(current)
        if !axTrustworthy {
            Log.info("AX snippet untrustworthy (suffix mismatch); falling back to char-grow")
            return await growSelectionLeftToWhitespace(initial: current)
        }

        if current.count >= target.length { return current }

        // Burst ⇧← — no clipboard polling between presses.
        let need = target.length - current.count
        for _ in 0..<need {
            KeyboardSynth.extendSelectionLeftChar()
        }

        try? await Task.sleep(nanoseconds: 40_000_000)
        let final = await copySelection(pb)
        return final.isEmpty ? current : final
    }

    /// Synthesize ⌘C and poll the pasteboard for the selected text.
    @MainActor
    private func copySelection(_ pb: NSPasteboard) async -> String {
        pb.clearContents()
        let baseline = pb.changeCount
        KeyboardSynth.copy()
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 15_000_000)
            if pb.changeCount != baseline,
               let s = pb.string(forType: .string) {
                return s
            }
        }
        return ""
    }

    // MARK: - Char-by-char selection grow (universal fallback)

    /// After system ⌥⇧← selects the last "word" (stopping at punctuation), this
    /// extends the selection leftward one character at a time using ⇧←, and
    /// stops when the newly added character is whitespace/newline. Rolls back
    /// one step in that case so whitespace isn't included.
    ///
    /// Works even in apps where AX can't read field contents, because we infer
    /// the added character by diffing the clipboard contents after each step.
    @MainActor
    private func growSelectionLeftToWhitespace(initial: String) async -> String {
        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)
        defer { restorePasteboard(pb, items: saved) }

        var current = initial
        let whitespace = CharacterSet.whitespacesAndNewlines

        for _ in 0..<200 { // safety cap
            KeyboardSynth.extendSelectionLeftChar()
            try? await Task.sleep(nanoseconds: 15_000_000)

            pb.clearContents()
            let baseline = pb.changeCount
            KeyboardSynth.copy()

            var extended: String? = nil
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 15_000_000)
                if pb.changeCount != baseline,
                   let s = pb.string(forType: .string) {
                    extended = s
                    break
                }
            }

            guard let new = extended, !new.isEmpty else {
                // Copy didn't produce anything; treat as end-of-field.
                break
            }
            if new.count <= current.count {
                // Couldn't extend further — already at start of field.
                break
            }
            let addedCount = new.count - current.count
            let addedPrefix = String(new.prefix(addedCount))
            // If any added scalar is whitespace, we overshot: roll back once.
            if addedPrefix.unicodeScalars.contains(where: { whitespace.contains($0) }) {
                KeyboardSynth.shrinkSelectionRightChar()
                try? await Task.sleep(nanoseconds: 10_000_000)
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

    /// Save clipboard, synth ⌘C, read resulting string, restore clipboard.
    @MainActor
    private func clipboardRead() async -> String {
        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)

        pb.clearContents()
        let baseline = pb.changeCount
        KeyboardSynth.copy()

        // Poll for up to ~400 ms for ⌘C to land.
        var result = ""
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
            if pb.changeCount != baseline,
               let s = pb.string(forType: .string), !s.isEmpty {
                result = s
                break
            }
        }

        restorePasteboard(pb, items: saved)
        return result
    }

    // MARK: - Pasteboard write

    @MainActor
    private func pasteReplacement(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)

        try? await Task.sleep(nanoseconds: 25_000_000) // 25ms
        KeyboardSynth.paste()

        // Give the paste time to land before we clobber the pasteboard back.
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
        restorePasteboard(pb, items: saved)
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
