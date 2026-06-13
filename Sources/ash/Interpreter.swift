import FoundationModels
import Foundation

/// Turns natural language into a `Plan` using the on-device model.
///
/// Stateless by design: the working directory is supplied per request so a
/// single warm process (the daemon) can serve calls from any directory. The
/// expensive cost is loading the model into the process once; creating a fresh
/// session per request after that is cheap and avoids conversation-history
/// bleed between unrelated requests.
enum Interpreter {

    private static let baseInstructions = """
    You are ash, a macOS command-line assistant. Translate the user's request \
    into exactly ONE shell command that runs in zsh on macOS.

    Output rules:
    - One command only. No markdown, no backticks, no comments, no prose.
    - Use only real, standard macOS/BSD tools and their real flags: ls, find, \
      grep, du, df, awk, sed, sort, head, tail, wc, cat, stat, ps, open, cp, \
      mv, mkdir, git.
    - Never invent file names, paths, flags, or text markers the user did not \
      mention. Operate on what the request actually says.
    - Quote any file path that contains a space or special character, e.g. \
      "My Report.txt" or 'Screenshot 1.png'. Unquoted spaces break the command.
    - Keep it simple. Prefer the shortest command that is correct. Use a single \
      pipeline rather than chaining unrelated commands.
    - Operate in the current working directory unless the user names another path.
    - When context lists "Available tools", prefer those (e.g. rg over grep, jq \
      for JSON) and do NOT use tools that aren't listed or standard.
    - When context lists files or git state, use the real names and branches \
      shown rather than guessing.

    This is macOS with BSD userland, NOT Linux. Use BSD-correct syntax:
    - Date math: `date -v-7d` (BSD), never GNU `date -d`.
    - In-place sed needs an arg: `sed -i ''`, never bare `sed -i`.
    - File size/format: `stat -f%z file` (BSD), never GNU `stat -c`.
    - Reverse a file with `tail -r`; `tac` is not installed.
    - BSD `find` has no `-printf`; use `-print`/`-exec` or `stat`.
    - Colored ls is `ls -G`, not `ls --color`.
    - Use `grep -E` for extended regex; BSD grep has no `-P` (PCRE).
    - If a g-prefixed GNU tool is listed (gsed, gdate), you may use it with GNU \
      syntax instead.

    Risk rules (set `risky`):
    - risky=false for read-only requests: listing, searching, counting, showing, \
      printing, sorting, disk usage.
    - risky=true if the command deletes, moves, renames, overwrites, creates, \
      installs, kills processes, changes permissions/ownership, needs sudo, or \
      touches system/network state.

    Examples (request -> command):
    list files in this directory in date order -> ls -lt
    list files including hidden ones -> ls -la
    show the 5 biggest files here -> du -ah . | sort -rh | head -n 5
    how much disk space is this folder using -> du -sh .
    find every python file changed in the last day -> find . -name '*.py' -mtime -1
    find files bigger than 100 MB -> find . -type f -size +100M
    count how many lines are in all swift files -> find . -name '*.swift' -print0 | xargs -0 wc -l
    count the files in this directory -> ls -1 | wc -l
    search for the word TODO in all files -> grep -rn 'TODO' .
    show me the running processes using the most memory -> ps aux | sort -rk4 | head -n 10
    what's my git status -> git status
    delete all files starting with foobar -> rm foobar*
    rename report.txt to final.txt -> mv report.txt final.txt
    make a folder called build -> mkdir build
    """

    /// Greedy decoding: deterministic, best for generating a precise command
    /// rather than creative text.
    private static let options = GenerationOptions(sampling: .greedy)

    /// Load the model into this process now, before the prompt is known.
    static func warmUp() {
        let session = LanguageModelSession(instructions: baseInstructions)
        session.prewarm()
    }

    /// Produce a Plan for a request, given a gathered environment context block.
    static func plan(for request: String, context: String) async throws -> Plan {
        let session = LanguageModelSession(instructions: baseInstructions)
        let prompt = "\(context)\nRequest: \(request)"
        let response = try await session.respond(to: prompt, generating: Plan.self, options: options)
        return response.content
    }
}
