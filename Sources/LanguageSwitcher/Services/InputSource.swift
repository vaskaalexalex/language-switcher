import Foundation
import Carbon.HIToolbox

/// Thin wrapper over Text Input Sources (TIS) used to flip the system
/// keyboard layout between English and Russian after a conversion.
enum InputSource {
    /// Inspects the given text and selects an enabled keyboard input source
    /// whose primary language matches its script.
    ///
    /// - Cyrillic characters (U+0400…U+04FF) → first input source whose
    ///   language list contains `"ru"` (Russian).
    /// - Otherwise → first input source whose language list contains `"en"`
    ///   (English).
    /// No-op if the current input source already matches.
    static func switchToMatch(_ text: String) {
        guard !text.isEmpty else { return }
        let wantCyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let targetPrefix = wantCyrillic ? "ru" : "en"

        if let current = currentLanguagePrefix(), current == targetPrefix {
            Log.info("InputSource: already on \(targetPrefix)")
            return
        }

        if selectSource(languagePrefix: targetPrefix) {
            Log.info("InputSource: switched to \(targetPrefix)")
        } else {
            Log.info("InputSource: no enabled source found for \(targetPrefix)")
        }
    }

    // MARK: - Queries

    private static func currentLanguagePrefix() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return firstLanguage(of: source).flatMap { languagePrefix($0) }
    }

    @discardableResult
    private static func selectSource(languagePrefix prefix: String) -> Bool {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsEnabled: kCFBooleanTrue as Any,
            kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue as Any,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue()
                as? [TISInputSource] else {
            return false
        }

        for source in list {
            guard let langs = languages(of: source) else { continue }
            if langs.contains(where: { languagePrefix($0) == prefix }) {
                return TISSelectInputSource(source) == noErr
            }
        }
        return false
    }

    // MARK: - Property helpers

    private static func languages(of source: TISInputSource) -> [String]? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return nil
        }
        let arr = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue()
        return arr as NSArray as? [String]
    }

    private static func firstLanguage(of source: TISInputSource) -> String? {
        languages(of: source)?.first
    }

    private static func languagePrefix(_ bcp47: String) -> String {
        if let dash = bcp47.firstIndex(of: "-") {
            return String(bcp47[..<dash])
        }
        return bcp47
    }
}
