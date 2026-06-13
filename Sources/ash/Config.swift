import Foundation

/// User configuration, loaded from ~/.config/ash/config.json.
///
/// Per-setting precedence is resolved at the call site: CLI flag > env var >
/// config file > built-in default. Decoding tolerates missing keys so older
/// config files keep working as new settings are added.
struct Config: Codable {
    /// Use a persistent warm daemon for fast (~1.3s) responses.
    var daemon: Bool = false
    /// What to do with a command judged safe (read-only). Default: run it.
    var safeAction: Action = .run
    /// What to do with a command judged risky. Default: show + copy, don't run.
    var riskyAction: Action = .copy
    /// Treat every command as safe: skip risk flagging entirely. Default: off.
    var yolo: Bool = false
    /// Append executed commands to the history log. Default: on.
    var logExecuted: Bool = true
    /// Extra command names to treat as safe to auto-run (user allowlist).
    var allow: [String] = []
    /// Extra substrings that mark a command as dangerous (user denylist).
    var deny: [String] = []
    /// How much environment context to feed the model. Default: full.
    var context: ContextLevel = .full
    /// Show a timing + token-count line after each command. Default: on.
    var metrics: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case daemon, safeAction, riskyAction, yolo, logExecuted, allow, deny, context, metrics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daemon = try c.decodeIfPresent(Bool.self, forKey: .daemon) ?? false
        safeAction = try c.decodeIfPresent(Action.self, forKey: .safeAction) ?? .run
        riskyAction = try c.decodeIfPresent(Action.self, forKey: .riskyAction) ?? .copy
        yolo = try c.decodeIfPresent(Bool.self, forKey: .yolo) ?? false
        logExecuted = try c.decodeIfPresent(Bool.self, forKey: .logExecuted) ?? true
        allow = try c.decodeIfPresent([String].self, forKey: .allow) ?? []
        deny = try c.decodeIfPresent([String].self, forKey: .deny) ?? []
        context = try c.decodeIfPresent(ContextLevel.self, forKey: .context) ?? .full
        metrics = try c.decodeIfPresent(Bool.self, forKey: .metrics) ?? true
    }

    // MARK: Paths

    static var dir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/ash", isDirectory: true)
    }
    static var fileURL: URL { dir.appendingPathComponent("config.json") }
    static var socketPath: String { dir.appendingPathComponent("ashd.sock").path }
    static var historyPath: String { dir.appendingPathComponent("history.log").path }

    // MARK: Loading

    /// Load config from disk, falling back to defaults if absent or unreadable.
    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return cfg
    }

    /// Write the config to disk, creating the directory if needed.
    func save() throws {
        try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL)
    }

    /// Resolve whether to use the daemon, honoring an optional CLI override and
    /// the ASH_DAEMON environment variable.
    static func useDaemon(cliOverride: Bool?) -> Bool {
        if let cli = cliOverride { return cli }
        if let env = ProcessInfo.processInfo.environment["ASH_DAEMON"] {
            return env == "1" || env.lowercased() == "true"
        }
        return load().daemon
    }
}
