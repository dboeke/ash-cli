import Foundation

/// Deterministic portability lint. macOS ships a BSD userland, so a handful of
/// GNU-only flags and tools that the on-device model occasionally emits fail at
/// runtime, often with a confusing error (`head -n -1` -> "illegal line count").
///
/// This is a *correctness* check, separate from `Safety`'s *danger* check. It
/// never blocks a command. Its only job is to flag the common GNU-isms so an
/// otherwise-"safe" command isn't auto-run straight into a failure: when one is
/// found, `main` routes the command to a review instead of running it, and
/// surfaces the BSD-correct form. The patterns are intentionally conservative,
/// matching well-known GNU syntax that has no BSD equivalent.
enum Portability {

    /// (regex, reason) pairs. Each reason names the BSD-correct form. Order is
    /// not significant; the first match wins. Flags are case-sensitive (`-P` is
    /// not `-p`), so these are matched without case folding.
    private static let gnuisms: [(NSRegularExpression, String)] = build([
        (#"\b(head|tail)\b[^|]*?-(n|c)[ ]*-[0-9]"#,
         "BSD `head`/`tail` take a positive count only; `-n -N` is GNU syntax (to drop the last line use `sed '$d'`)"),
        (#"\b(head|tail)\b[^|]*?--(lines|bytes)=-"#,
         "BSD `head`/`tail` take a positive count only; `--lines=-N` is GNU syntax (to drop the last line use `sed '$d'`)"),
        (#"\bdate\b[^|]*?[ ]-d([ =']|")"#,
         "BSD `date` has no `-d`; use `-v` for date math (e.g. `date -v-7d`)"),
        (#"\bstat\b[^|]*?[ ]-c([ =']|")"#,
         "BSD `stat` uses `-f` format strings, not GNU `-c` (e.g. `stat -f%z`)"),
        (#"\b(grep|egrep|fgrep)\b[^|]*?[ ]-[A-Za-z]*P"#,
         "BSD `grep` has no `-P` (PCRE); use `-E` for extended regex"),
        (#"\b(grep|egrep|fgrep)\b[^|]*?--perl-regexp"#,
         "BSD `grep` has no `--perl-regexp`; use `-E` for extended regex"),
        (#"(^|\|)[ ]*tac\b"#,
         "`tac` isn't on macOS; reverse a file with `tail -r`"),
        (#"\bls\b[^|]*?--color"#,
         "BSD `ls` has no `--color`; use `-G`"),
        (#"\bfind\b[^|]*?-printf\b"#,
         "BSD `find` has no `-printf`; use `-print`/`-exec` or `stat`"),
        (#"\bsed\b[ ]+-i[ ]+(-[en]\b|['"]?[sypdg]|/)"#,
         "BSD `sed -i` needs a backup-suffix arg; use `sed -i ''` to edit in place"),
    ])

    /// The first GNU-ism found in `command`, as a human-readable reason naming
    /// the BSD-correct form, or nil if the command looks BSD-safe.
    static func gnuism(in command: String) -> String? {
        let range = NSRange(command.startIndex..., in: command)
        for (re, reason) in gnuisms where re.firstMatch(in: command, options: [], range: range) != nil {
            return reason
        }
        return nil
    }

    private static func build(_ raw: [(String, String)]) -> [(NSRegularExpression, String)] {
        raw.compactMap { pattern, reason in
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (re, reason)
        }
    }
}
