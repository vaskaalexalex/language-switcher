import Foundation

/// Simple file+stderr logger. Writes to ~/Library/Logs/LanguageSwitcher.log.
enum Log {
    static let url: URL = {
        let fm = FileManager.default
        let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("LanguageSwitcherMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()

    private static let queue = DispatchQueue(label: "punto.log")

    private static let maxBytes = 256_000
    private static let keepBytes = 128_000

    /// Keep the log from growing without bound: when it exceeds `maxBytes`,
    /// rewrite it to the most recent `keepBytes`. Otherwise the file fills with
    /// weeks-old entries and the diagnostics export surfaces stale history
    /// instead of the conversion the user is trying to report. Call at launch.
    static func trimIfNeeded() {
        queue.async {
            guard let data = try? Data(contentsOf: url), data.count > maxBytes else { return }
            let kept = trimmedTail(data, keepBytes: keepBytes)
            try? kept.write(to: url, options: .atomic)
        }
    }

    /// Pure: the last `keepBytes` of `data`. If the cut lands in the middle of
    /// a line, advance to the start of the next line so the result begins on a
    /// clean log entry; if it lands exactly on a line boundary, keep that line.
    static func trimmedTail(_ data: Data, keepBytes: Int) -> Data {
        guard data.count > keepBytes else { return data }
        let bytes = [UInt8](data)
        var start = bytes.count - keepBytes
        if start > 0 && bytes[start - 1] != 0x0A {
            var i = start
            while i < bytes.count && bytes[i] != 0x0A { i += 1 }
            if i < bytes.count { start = i + 1 }
        }
        return Data(bytes[start...])
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: @autoclosure () -> String,
                     file: String = #fileID, line: Int = #line) {
        let msg = message()
        let ts = dateFormatter.string(from: Date())
        let base = "\(file):\(line)"
        let line = "[\(ts)] \(base) \(msg)\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
        queue.async {
            append(line)
        }
    }

    private static func append(_ text: String) {
        let data = text.data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            do {
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        } else {
            try? data.write(to: url)
        }
    }
}
