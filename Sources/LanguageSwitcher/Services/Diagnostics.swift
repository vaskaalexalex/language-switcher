import AppKit

/// Exports the app log so a bug report can be handed back to the developer —
/// "here is what I typed and what it changed to". The log already records each
/// conversion (including a one-line `SUMMARY ...` per trigger); these helpers
/// just make it reachable from the UI.
enum Diagnostics {
    static var logURL: URL { Log.url }

    /// A self-contained snapshot: a short header (app + OS version, time, path)
    /// followed by the tail of the log, capped so it stays paste-able.
    static func recentText(maxBytes: Int = 64_000) -> String {
        let header = """
        LanguageSwitcher diagnostics
        app:      \(AppVersion.displayString)
        macOS:    \(ProcessInfo.processInfo.operatingSystemVersionString)
        captured: \(timestamp())
        log:      \(logURL.path)
        ----------------------------------------
        """
        return header + "\n" + tail(of: logURL, maxBytes: maxBytes)
    }

    /// Copy the recent diagnostics to the general pasteboard. Returns the
    /// number of characters copied (for a log/confirmation).
    @discardableResult
    static func copyRecentToPasteboard(maxBytes: Int = 64_000) -> Int {
        let text = recentText(maxBytes: maxBytes)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return text.count
    }

    /// Reveal the log file in Finder so the user can attach it to a report.
    static func revealLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    // MARK: - Private

    private static func tail(of url: URL, maxBytes: Int) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return "(no log yet — trigger a conversion first, then copy again)"
        }
        let truncated = data.count > maxBytes
        let slice = truncated ? data.suffix(maxBytes) : data
        let text = String(decoding: slice, as: UTF8.self)
        // If we cut mid-file, drop the partial first line so it reads cleanly.
        if truncated, let nl = text.firstIndex(of: "\n") {
            return "…(truncated to last \(maxBytes / 1000) KB)\n" + String(text[text.index(after: nl)...])
        }
        return text
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
