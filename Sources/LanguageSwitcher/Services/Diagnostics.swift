import AppKit

/// Exports the app log so a bug report can be handed back to the developer —
/// "here is what I typed and what it changed to". The log already records each
/// conversion (including a one-line `SUMMARY ...` per trigger); these helpers
/// just make it reachable from the UI.
enum Diagnostics {
    static var logURL: URL { Log.url }

    /// A self-contained snapshot for a bug report: a short header (app + OS
    /// version, time, path) plus only the last `conversations` conversions, so
    /// the report is focused on what just happened, not weeks of history.
    static func recentText(conversations: Int = 5) -> String {
        let header = """
        LanguageSwitcher diagnostics
        app:      \(AppVersion.displayString)
        macOS:    \(ProcessInfo.processInfo.operatingSystemVersionString)
        captured: \(timestamp())
        log:      \(logURL.path)
        showing:  last \(conversations) conversions
        ----------------------------------------
        """
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty else {
            return header + "\n(no log yet — trigger a conversion first, then copy again)"
        }
        // Bound memory, then keep only the last N conversions.
        let bounded = data.count > 512_000 ? Data(data.suffix(512_000)) : data
        let text = String(decoding: bounded, as: UTF8.self)
        return header + "\n" + lastConversations(in: text, count: conversations)
    }

    /// Pure: keep only the last `count` conversions from `log`. Each conversion
    /// begins at a "Trigger fired" line; everything from the Nth-from-last such
    /// line onward is returned. Fewer than `count` conversions → the whole log.
    static func lastConversations(in log: String, count: Int) -> String {
        guard count > 0 else { return "" }
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        let starts = lines.indices.filter { lines[$0].contains("Trigger fired") }
        guard starts.count > count else { return log }
        let from = starts[starts.count - count]
        return lines[from...].joined(separator: "\n")
    }

    /// Copy the recent diagnostics to the general pasteboard. Returns the
    /// number of characters copied (for a log/confirmation).
    @discardableResult
    static func copyRecentToPasteboard(conversations: Int = 5) -> Int {
        let text = recentText(conversations: conversations)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return text.count
    }

    /// Reveal the log file in Finder so the user can attach it to a report.
    static func revealLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    /// Empty the log so the next capture contains only a fresh repro.
    static func clearLog() {
        try? Data().write(to: logURL, options: .atomic)
        Log.info("Diagnostics log cleared")
    }

    // MARK: - Private

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
