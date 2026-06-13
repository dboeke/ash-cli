import Foundation

/// How much environment context to feed the model.
enum ContextLevel: String, Codable {
    case off    // just the working directory
    case light  // + project type, git branch, available tools (no file listing)
    case full   // + a truncated directory listing and git status
}

/// Gathers cheap, local signals about the current environment and formats them
/// into a compact block prepended to the model prompt. Everything here is local
/// and never leaves the machine (the model is on-device), so feeding filenames
/// and git state costs nothing in privacy.
enum Context {

    private static let maxListing = 50
    private static let maxStatus = 15

    static func gather(cwd: String, level: ContextLevel) -> String {
        var lines = ["Current working directory: \(cwd)"]
        if level == .off {
            return lines.joined(separator: "\n")
        }

        let fm = FileManager.default

        // Project type, inferred from marker files.
        if let project = projectMarkers(cwd: cwd, fm: fm) {
            lines.append("Project: \(project)")
        }

        // Git branch (read .git/HEAD directly - no subprocess).
        if let branch = gitBranch(cwd: cwd) {
            lines.append("Git branch: \(branch)")
        }

        // Available tools, so the model picks ones that exist here.
        let tools = Tools.available()
        if !tools.isEmpty {
            lines.append("Available tools: \(tools.joined(separator: ", "))")
        }

        if level == .full {
            // Truncated directory listing.
            if let entries = try? fm.contentsOfDirectory(atPath: cwd) {
                let visible = entries.filter { !$0.hasPrefix(".") }.sorted()
                let shown = visible.prefix(maxListing).map { name -> String in
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: cwd + "/" + name, isDirectory: &isDir)
                    return isDir.boolValue ? name + "/" : name
                }
                if !shown.isEmpty {
                    var line = "Files here: " + shown.joined(separator: "  ")
                    if visible.count > maxListing { line += "  (+\(visible.count - maxListing) more)" }
                    lines.append(line)
                }
            }
            // Short git status.
            if let status = gitStatus(cwd: cwd) {
                lines.append("Git status:\n\(status)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Probes

    private static func projectMarkers(cwd: String, fm: FileManager) -> String? {
        let markers: [(file: String, kind: String)] = [
            ("package.json", "Node/JS (use npm/yarn/pnpm scripts)"),
            ("Cargo.toml", "Rust (use cargo)"),
            ("go.mod", "Go (use go)"),
            ("pyproject.toml", "Python (use the project's tooling)"),
            ("requirements.txt", "Python (pip)"),
            ("Gemfile", "Ruby (bundler)"),
            ("Package.swift", "Swift (use swift build/test)"),
            ("pom.xml", "Java (maven)"),
            ("build.gradle", "Java/Kotlin (gradle)"),
            ("CMakeLists.txt", "CMake"),
            ("Makefile", "Make (use make targets)"),
            ("Dockerfile", "Docker"),
        ]
        let found = markers.filter { fm.fileExists(atPath: cwd + "/" + $0.file) }
        guard !found.isEmpty else { return nil }
        return found.map(\.kind).joined(separator: "; ")
    }

    private static func gitBranch(cwd: String) -> String? {
        let head = cwd + "/.git/HEAD"
        guard let contents = try? String(contentsOfFile: head, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return "detached" // detached HEAD (raw sha)
    }

    private static func gitStatus(cwd: String) -> String? {
        guard FileManager.default.fileExists(atPath: cwd + "/.git") else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", cwd, "status", "--porcelain"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").prefix(maxStatus).joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
