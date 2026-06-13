import Foundation

/// Deterministic safety gate. ash auto-runs a command ONLY if every part of it
/// is positively recognized as non-destructive: read-only inspection, or purely
/// additive creation (mkdir/touch) which is reversible. Anything else - writes,
/// deletes, overwrites, privileged ops, or commands we don't recognize -
/// defaults to "risky", so the worst case is showing/copying a command instead
/// of silently running something unexpected.
///
/// On privilege: we do NOT try to predict whether a command will need elevated
/// permissions. A non-`sudo` command that lacks permission simply fails with no
/// effect, which is harmless. The genuine danger is an *explicit* `sudo` (root
/// can damage the system), and that is caught by the denylist below.
enum Safety {

    /// Commands whose normal use only reads or inspects, never mutates state.
    /// find/sed/awk/git are read-only only without their mutating forms; handled
    /// in `assess`.
    private static let readOnlyCommands: Set<String> = [
        "ls", "cat", "bat", "head", "tail", "wc", "stat", "file", "du", "df",
        "pwd", "echo", "printf", "date", "cal", "whoami", "id", "hostname",
        "uname", "uptime", "env", "printenv", "grep", "egrep", "fgrep", "rg",
        "ag", "ack", "find", "fd", "locate", "which", "type", "sort", "uniq",
        "cut", "tr", "awk", "sed", "jq", "yq", "column", "comm", "diff", "cmp",
        "md5", "shasum", "sha256sum", "cksum", "tree", "ps", "history", "tac",
        "nl", "fold", "rev", "basename", "dirname", "realpath", "readlink",
        "seq", "tldr", "man", "look", "strings", "xxd", "od", "less", "more",
        "git",  // gated to read-only subcommands in `assess`
    ]

    /// Commands that only add new, reversible things. Safe to auto-run.
    private static let additiveCommands: Set<String> = [
        "mkdir", "touch",
    ]

    /// Outcome of assessing a command.
    struct Assessment {
        let isSafe: Bool       // safe to auto-run
        let reason: String?    // why it's risky (nil when safe)
    }

    /// Assess a command. `extraSafe` are user-allowlisted command names;
    /// `extraDanger` are user denylist substrings (lowercased match).
    static func assess(_ command: String,
                       extraSafe: [String] = [],
                       extraDanger: [String] = []) -> Assessment {
        if let reason = dangerReason(for: command, extraDanger: extraDanger) {
            return Assessment(isSafe: false, reason: reason)
        }

        let allowedReadOnly = readOnlyCommands.union(extraSafe.map { $0.lowercased() })

        for segment in command.components(separatedBy: "|") {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.split(separator: " ").first else {
                return Assessment(isSafe: false, reason: "empty command segment")
            }
            let name = (String(first) as NSString).lastPathComponent
            let low = trimmed.lowercased()

            if additiveCommands.contains(name) {
                continue  // create-only: reversible, safe
            }
            guard allowedReadOnly.contains(name) else {
                return Assessment(isSafe: false, reason: "this may modify files or system state")
            }

            switch name {
            case "find":
                if low.contains("-delete") || low.contains("-exec") || low.contains("-ok") {
                    return Assessment(isSafe: false, reason: "find can delete or run other commands")
                }
            case "sed", "awk":
                if low.contains("-i") {
                    return Assessment(isSafe: false, reason: "in-place edit writes files")
                }
            case "git":
                let readOnlyGit: Set<String> = ["status", "log", "diff", "show", "branch",
                                                "remote", "blame", "describe", "tag", "shortlog"]
                let parts = trimmed.split(separator: " ").map(String.init)
                guard parts.count >= 2, readOnlyGit.contains(parts[1]) else {
                    return Assessment(isSafe: false, reason: "git subcommand may change the repo")
                }
            default:
                break
            }
        }
        return Assessment(isSafe: true, reason: nil)
    }

    /// Returns a human-readable reason the command is explicitly dangerous, or
    /// nil. This is the hard denylist that always blocks auto-run.
    static func dangerReason(for command: String, extraDanger: [String] = []) -> String? {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cmd.lowercased()

        let patterns: [(String, String)] = [
            ("rm -rf", "recursive force delete"),
            ("rm -fr", "recursive force delete"),
            ("rm -r", "recursive delete"),
            ("sudo", "runs with root privileges"),
            ("mkfs", "formats a filesystem"),
            ("dd ", "raw disk write"),
            (":(){", "fork bomb"),
            ("chmod -r", "recursive permission change"),
            ("chown -r", "recursive ownership change"),
            ("> /dev/", "writes to a device file"),
            ("diskutil", "modifies disks"),
            ("shutdown", "powers down the machine"),
            ("reboot", "restarts the machine"),
            ("kill -9", "force-kills a process"),
            ("killall", "kills processes by name"),
            ("launchctl", "changes system daemons"),
            ("defaults write", "changes system/app settings"),
            ("curl ", "fetches and may run remote content"),
            ("wget ", "fetches and may run remote content"),
            ("git push", "publishes to a remote"),
            ("git reset --hard", "discards local changes"),
            ("git clean", "deletes untracked files"),
            ("npm publish", "publishes a package"),
            ("brew uninstall", "removes installed software"),
            ("pip uninstall", "removes installed software"),
        ]
        for (needle, reason) in patterns where lower.contains(needle) {
            return reason
        }
        for needle in extraDanger where lower.contains(needle.lowercased()) {
            return "matches your denylist (\(needle))"
        }

        if lower.hasPrefix("rm ") || lower == "rm" { return "deletes files" }

        if cmd.contains(">") && !cmd.contains(">>") { return "overwrites a file via >" }

        for meta in [";", "&&", "||", "`", "$(", "&"] where cmd.contains(meta) {
            return "chains or backgrounds multiple commands"
        }

        return nil
    }
}
