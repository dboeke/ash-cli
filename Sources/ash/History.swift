import Foundation

/// Append-only audit log of commands ash actually executed. Useful for trust
/// and debugging, especially with auto-run enabled.
enum History {

    /// Append one execution record. `flagged` marks commands that were risky but
    /// run anyway (forced or yolo). Best-effort; never blocks the command.
    static func record(command: String, cwd: String, flagged: Bool) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let mark = flagged ? "RISKY" : "ok"
        let line = "\(stamp)\t\(mark)\t\(cwd)\t\(command)\n"

        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        let path = Config.historyPath
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    /// Return the last `limit` lines of the log (most recent last).
    static func tail(_ limit: Int) -> String {
        guard let text = try? String(contentsOfFile: Config.historyPath, encoding: .utf8) else {
            return ""
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(limit).joined(separator: "\n")
    }
}
