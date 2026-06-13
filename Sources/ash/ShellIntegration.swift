import Foundation

/// Adds/removes a small snippet in the user's shell startup file so the daemon
/// is warmed when a terminal opens. Uses a sentinel marker block so the edit is
/// idempotent and cleanly reversible (the conda/nvm/rbenv pattern).
enum ShellIntegration {

    static let beginMarker = "# >>> ash startup >>>"
    static let endMarker = "# <<< ash startup <<<"

    /// Detected shell name, its startup file, and whether it's fish (different syntax).
    struct Target {
        let name: String
        let rcPath: String
        let isFish: Bool
    }

    /// Resolve which startup file to edit from $SHELL, with an env override for
    /// testing or non-standard setups.
    static func detect() -> Target? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["ASH_SHELL_RC"], !override.isEmpty {
            return Target(name: "custom", rcPath: override, isFish: override.contains("fish"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shellName = ((env["SHELL"] ?? "") as NSString).lastPathComponent
        switch shellName {
        case "zsh":
            return Target(name: "zsh", rcPath: home + "/.zshrc", isFish: false)
        case "bash":
            // macOS Terminal opens login shells, which read .bash_profile.
            return Target(name: "bash", rcPath: home + "/.bash_profile", isFish: false)
        case "fish":
            return Target(name: "fish", rcPath: home + "/.config/fish/config.fish", isFish: true)
        default:
            return nil
        }
    }

    private static func snippet(for target: Target) -> String {
        let shellArg = target.name == "custom" ? "zsh" : target.name
        let body = target.isFish
            ? "command -q ash; and ash init fish | source"
            : "command -v ash >/dev/null 2>&1 && eval \"$(ash init \(shellArg))\""
        return "\(beginMarker)\n\(body)\n\(endMarker)"
    }

    /// The line a user can paste manually if their shell isn't recognized.
    static var manualSnippet: String {
        "command -v ash >/dev/null 2>&1 && eval \"$(ash init zsh)\""
    }

    /// The shell function + daemon warmup emitted by `ash init <shell>`. The
    /// function adds inline injection: when ash chooses the "inject" action it
    /// writes the command to ASH_INJECT_FILE, and this wrapper loads it at your
    /// prompt (so it runs in your real shell, with full context, nothing copied).
    static func initScript(for shell: String) -> String {
        switch shell {
        case "fish":
            return """
            function ash
                set -l __ash_inj (command mktemp -t ash-inject)
                ASH_INJECT_FILE=$__ash_inj command ash $argv
                set -l __ash_rc $status
                if test -s "$__ash_inj"
                    commandline --replace -- (command cat -- "$__ash_inj")
                end
                command rm -f -- "$__ash_inj"
                return $__ash_rc
            end
            command ash launch >/dev/null 2>&1
            """
        case "bash":
            // bash cannot preload the prompt cleanly, so it has no wrapper:
            // inject falls back to print + one-key copy. Just warm the daemon.
            return "command ash launch >/dev/null 2>&1"
        default:  // zsh
            return """
            ash() {
              local __ash_inj
              __ash_inj="$(command mktemp -t ash-inject)" || { command ash "$@"; return $? }
              ASH_INJECT_FILE="$__ash_inj" command ash "$@"
              local __ash_rc=$?
              if [[ -s "$__ash_inj" ]]; then
                print -rz -- "$(command cat -- "$__ash_inj")"
              fi
              command rm -f -- "$__ash_inj"
              return $__ash_rc
            }
            command ash launch >/dev/null 2>&1
            """
        }
    }

    /// Add the startup snippet. Returns a user-facing status message.
    static func enable() -> String {
        guard let t = detect() else {
            return "Could not detect your shell. Add this to your shell startup file manually:\n\(manualSnippet)"
        }
        let existing = (try? String(contentsOfFile: t.rcPath, encoding: .utf8)) ?? ""
        if existing.contains(beginMarker) {
            return "Shell startup already configured in \(t.rcPath)."
        }
        let separator = (existing.isEmpty || existing.hasSuffix("\n")) ? "" : "\n"
        let newContent = existing + separator + "\n" + snippet(for: t) + "\n"
        do {
            let dir = URL(fileURLWithPath: t.rcPath).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try newContent.write(toFile: t.rcPath, atomically: true, encoding: .utf8)
            return "Added ash startup to \(t.rcPath) (\(t.name)). It takes effect in new terminals."
        } catch {
            return "Could not write \(t.rcPath): \(error)"
        }
    }

    /// Remove the startup snippet. Returns a user-facing status message.
    static func disable() -> String {
        guard let t = detect() else { return "Shell not detected; nothing to remove." }
        guard let existing = try? String(contentsOfFile: t.rcPath, encoding: .utf8),
              existing.contains(beginMarker) else {
            return "No ash startup block found."
        }
        do {
            try removeBlock(from: existing).write(toFile: t.rcPath, atomically: true, encoding: .utf8)
            return "Removed ash startup from \(t.rcPath)."
        } catch {
            return "Could not write \(t.rcPath): \(error)"
        }
    }

    /// Strip the marker block (and the single blank line we inserted before it).
    private static func removeBlock(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(of: beginMarker),
              let end = lines.firstIndex(of: endMarker), end >= begin else {
            return text
        }
        lines.removeSubrange(begin...end)
        if begin > 0, begin - 1 < lines.count, lines[begin - 1].isEmpty {
            lines.remove(at: begin - 1)
        }
        return lines.joined(separator: "\n")
    }
}
