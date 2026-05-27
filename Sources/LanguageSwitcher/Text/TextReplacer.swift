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
        let caretPosition = axRange.map { $0.location + $0.length }
        var axTarget: TokenTarget?
        var axFullText: String?
        if let element {
            axFullText = AccessibilityBridge.stringAttribute(element, kAXValueAttribute as String)
            axTarget = axFullText.flatMap { Self.computeTokenTarget(in: $0, caretHint: caretPosition) }
                .map { TokenTarget(start: $0.start, length: $0.length, snippet: $0.snippet) }
        }
        if let t = axTarget {
            Log.info("AX target: range=(\(t.start),\(t.length)) snippet=\(t.snippet.debugDescription)")
        }

        // 3) Resolve text to convert.
        var selected = ""
        if hasSelection {
            selected = axSelectedText(element)
            if selected.isEmpty { selected = await clipboardRead() }
        } else if let t = axTarget, let element {
            // Electron/Cursor: read the token straight from AXValue — no word-select needed.
            if let full = axFullText, let snippet = Self.snippet(from: full, start: t.start, length: t.length) {
                selected = snippet
                Log.info("Using AX value slice (\(snippet.count) chars)")
            }

            if selected.isEmpty {
                let newRange = CFRange(location: t.start, length: t.length)
                let axSet = AccessibilityBridge.setRangeAttribute(
                    element, kAXSelectedTextRangeAttribute as String, newRange)
                Log.info("AX set range=\(axSet)")

                if axSet {
                    let verified = await waitUntil(pollNanoseconds: 5_000_000, maxAttempts: 6) {
                        let verify = self.axSelectedText(element)
                        return !verify.isEmpty && verify.count == t.length
                    }
                    if verified {
                        selected = axSelectedText(element)
                        Log.info("AX selection verified (\(selected.count) chars)")
                    }
                }
            }

            if selected.isEmpty {
                Log.info("Selecting exact token length via synth (\(t.length) chars)")
                selected = await selectExactTokenViaSynth(length: t.length)
                if selected.isEmpty {
                    selected = t.snippet
                    Log.info("Synth select empty; falling back to AX target snippet")
                }
            }
        } else {
            Log.info("No AX data, using synth + char-grow")
            KeyboardSynth.selectPreviousWord()
            selected = await waitForSelection(element: element, viaClipboard: true, maxAttempts: 5, pollNanoseconds: 8_000_000)
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

        var replaced = false
        if let element, let t = axTarget, let full = axFullText {
            replaced = await tryAXValueReplacement(
                element: element, fullText: full, target: t, converted: converted)
        }

        if !replaced, let element {
            if axSelectedText(element).isEmpty, let t = axTarget {
                Log.info("Ensuring selection before AX/paste replacement")
                _ = await selectExactTokenViaSynth(length: t.length)
            }
            replaced = await tryAXReplacement(element: element, converted: converted)
        }

        if !replaced {
            if let t = axTarget, axSelectedText(element).isEmpty {
                _ = await selectExactTokenViaSynth(length: t.length)
            }
            await pasteReplacement(converted)
        }

        if Preferences.shared.switchKeyboardLayout {
            InputSource.switchToMatch(converted)
        }

        let elapsed = (CACurrentMediaTime() - started) * 1000
        Log.info(String(format: "Conversion finished in %.0f ms", elapsed))
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
        guard let target = Self.computeTokenTarget(in: fullText, caretHint: caretHint) else { return nil }
        return TokenTarget(start: target.start, length: target.length, snippet: target.snippet)
    }

    static func snippet(from text: String, start: Int, length: Int) -> String? {
        let ns = text as NSString
        guard start >= 0, length > 0, start + length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: start, length: length))
    }

    static func replaceToken(in text: String, start: Int, length: Int, replacement: String) -> String {
        let ns = text as NSString
        guard start >= 0, length >= 0, start + length <= ns.length else { return text }
        return ns.replacingCharacters(in: NSRange(location: start, length: length), with: replacement)
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

        let lastChar = ns.substring(with: NSRange(location: effectiveEnd - 1, length: 1))
        guard endsWithLetterOrDigit(lastChar) else { return nil }

        let start = scanBackToWhitespace(in: ns, from: effectiveEnd, whitespace: whitespace)
        let length = effectiveEnd - start
        guard length > 0 else { return nil }

        let snippet = ns.substring(with: NSRange(location: start, length: length))
        return (start: start, length: length, snippet: snippet)
    }

    private static func endsWithLetterOrDigit(_ ch: String) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
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
        let expected = Self.replaceToken(
            in: fullText, start: target.start, length: target.length, replacement: converted)

        guard AccessibilityBridge.setStringAttribute(
            element, kAXValueAttribute as String, expected
        ) else {
            Log.info("AX value write failed")
            return false
        }

        let newCaret = target.start + (converted as NSString).length
        _ = AccessibilityBridge.setRangeAttribute(
            element, kAXSelectedTextRangeAttribute as String,
            CFRange(location: newCaret, length: 0))

        let ok = await waitUntil(pollNanoseconds: 5_000_000, maxAttempts: 10) {
            guard let current = AccessibilityBridge.stringAttribute(element, kAXValueAttribute as String) else {
                return false
            }
            return current == expected
        }
        Log.info("AX value write \(ok ? "verified" : "unverified")")
        return ok
    }

    @MainActor
    private func tryAXReplacement(element: AXUIElement, converted: String) async -> Bool {
        guard AccessibilityBridge.setStringAttribute(
            element, kAXSelectedTextAttribute as String, converted
        ) else {
            Log.info("AX direct write failed")
            return false
        }

        let ok = await waitUntil(pollNanoseconds: 5_000_000, maxAttempts: 8) {
            let sel = self.axSelectedText(element)
            return sel.isEmpty || sel == converted
        }
        Log.info("AX direct write \(ok ? "verified" : "unverified")")
        return ok
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

    /// Select exactly `length` characters left of the caret using ⇧← bursts.
    /// Avoids ⌥⇧← word boundaries that split tokens like `e,рал` in Electron.
    @MainActor
    private func selectExactTokenViaSynth(length: Int) async -> String {
        guard length > 0 else { return "" }

        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)
        defer { restorePasteboard(pb, items: saved) }

        for _ in 0..<length {
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

        KeyboardSynth.paste()

        // Brief pause for paste to land, then restore clipboard.
        try? await Task.sleep(nanoseconds: 15_000_000)
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
