import Foundation

/// Detects which notable CLI tools are installed, so the model prefers commands
/// that actually exist on this machine (e.g. `rg` over `grep`, `jq` for JSON).
///
/// Detection scans $PATH directories directly - no subprocess spawning - and the
/// result is cached to disk because installed tools rarely change.
enum Tools {

    /// Tools whose presence meaningfully changes which command to generate.
    /// (Ubiquitous basics like ls/cat/grep are assumed and omitted.)
    static let notable: Set<String> = [
        // search / files
        "rg", "ag", "fd", "fzf", "bat", "eza", "exa", "tree", "rsync",
        // data
        "jq", "yq", "xsv", "csvkit", "pandoc",
        // http / hosting
        "curl", "wget", "http", "gh", "glab",
        // containers / infra
        "docker", "podman", "kubectl", "helm", "terraform",
        // languages / runtimes
        "python3", "node", "deno", "bun", "ruby", "go", "cargo", "rustc", "java",
        // package managers
        "brew", "npm", "pnpm", "yarn", "pip", "pip3", "pipx", "cargo",
        // build
        "make", "cmake", "ninja", "gradle", "mvn",
        // media
        "ffmpeg", "magick", "convert",
        // GNU coreutils variants (signal that GNU syntax is available)
        "gsed", "gdate", "gawk", "gls", "gfind", "gstat", "grealpath", "coreutils",
        // misc
        "tmux", "git", "svn", "sqlite3", "psql", "redis-cli",
    ]

    private static var cachePath: String {
        Config.dir.appendingPathComponent("tools.json").path
    }

    /// Available notable tools, sorted. Uses the disk cache if present.
    static func available() -> [String] {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
           let cached = try? JSONDecoder().decode([String].self, from: data) {
            return cached
        }
        return refresh()
    }

    /// Rescan $PATH and rewrite the cache. Returns the fresh list.
    @discardableResult
    static func refresh() -> [String] {
        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let fm = FileManager.default
        var present = Set<String>()
        for dir in path.split(separator: ":") {
            guard let entries = try? fm.contentsOfDirectory(atPath: String(dir)) else { continue }
            for name in entries where notable.contains(name) {
                present.insert(name)
            }
        }
        let result = present.sorted()
        try? fm.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: URL(fileURLWithPath: cachePath))
        }
        return result
    }
}
