import Foundation

/// Occasional, non-naggy tips. Each tip is rate-limited via a timestamp file so
/// it shows at most once per day.
enum Hints {

    private static let dayInSeconds: Double = 86_400

    private static func stampPath(_ name: String) -> String {
        Config.dir.appendingPathComponent("hint-\(name)").path
    }

    /// Returns true at most once per 24 hours for a given tip name, and records
    /// the time when it does.
    static func due(_ name: String) -> Bool {
        let now = Date().timeIntervalSince1970
        if let s = try? String(contentsOfFile: stampPath(name), encoding: .utf8),
           let last = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)),
           now - last < dayInSeconds {
            return false
        }
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        try? "\(now)".write(toFile: stampPath(name), atomically: true, encoding: .utf8)
        return true
    }
}
