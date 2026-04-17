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
