import FoundationModels
import Foundation

// MARK: - Terminal styling

enum Style {
    static let isTTY = isatty(STDOUT_FILENO) == 1
    static func wrap(_ s: String, _ code: String) -> String {
        isTTY ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s
    }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func green(_ s: String) -> String { wrap(s, "32") }
    static func yellow(_ s: String) -> String { wrap(s, "33") }
    static func cyan(_ s: String) -> String { wrap(s, "36") }
}

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let version = "0.1.1"

func printUsage() {
    print("""
    ash \(version) - agentic shell

    USAGE:
      ash <natural language request>
      ash config [<setting> <value>]
      ash history [N]             Show the last N executed commands (default 30).
      ash tools [refresh]         Show (or rescan) notable CLI tools ash detects.
      ash init [zsh|bash|fish]    Print shell integration; add: eval "$(ash init zsh)"
      ash launch                  Ensure the daemon is running (instant; for shell startup).

    ACTION OPTIONS (override the per-run behavior):
      -r, --run               Execute the command.
          --inject            Load the command at your shell prompt (needs `ash init`).
      -i, --confirm           Show the command and ask y/n before running.
      -c, --print-and-copy    Show the command and copy it to the clipboard (don't run).
      -p, --print             Show the command only (don't run, don't copy).
      -n, --dry-run           Alias for --print-and-copy.
      -y, --yolo              Run even if the command looks dangerous.
          --no-yolo           Force risk checking on for this run.

    OTHER OPTIONS:
      -q, --quiet             Suppress ash's narration (just run, or print the bare command).
          --json              Print the plan as JSON and exit (no execution).
          --daemon            Use the warm daemon for this run (fast).
          --no-daemon         Run in-process for this run.
      -h, --help              Show this help.
      -v, --version           Show version.

    CONFIG (~/.config/ash/config.json) - set defaults so you don't need flags:
      ash config daemon on|off
      ash config daemon-timeout <minutes>               (0 = never; default: 0)
      ash config safe-action  run|inject|confirm|copy|print   (default: run)
      ash config risky-action run|inject|confirm|copy|print   (default: inject)
      ash config yolo on|off                            (default: off)
      ash config context off|light|full                (default: full)
      ash config metrics on|off                         (default: on)
      ash config log on|off                             (default: on)
      ash config allow <command>      Treat a command as safe to auto-run.
      ash config deny <pattern>       Always flag commands containing <pattern>.
      ash config                      Show all current settings.

    EXAMPLES:
      ash list files in this directory in date order
      ash -c delete all logs older than a week
      ash config safe-action confirm   # always ask before running
      ash -qp count the files here     # print just the bare command, for scripts
    """)
}

// MARK: - Argument handling

var argv = Array(CommandLine.arguments.dropFirst())

// Hidden subcommand: run the daemon server loop.
if argv.first == "__daemon" {
    await Daemon.serve()
}

// `ash launch`: ensure the daemon is running and return instantly. Only acts
// when the daemon is enabled, so the shell-startup hook can call it always.
if argv.first == "launch" {
    if Config.load().daemon { Daemon.launch() }
    exit(0)
}

// `ash init <shell>`: print the shell integration (inject wrapper + daemon
// warmup) for `eval "$(ash init zsh)"`. Defaults to zsh.
if argv.first == "init" {
    let shell = argv.dropFirst().first ?? "zsh"
    print(ShellIntegration.initScript(for: shell))
    exit(0)
}

// `ash history [N]`: show the last N executed commands (default 30).
if argv.first == "history" {
    let n = Int(argv.dropFirst().first ?? "") ?? 30
    let out = History.tail(n)
    if out.isEmpty { print("(no history yet)") } else { print(out) }
    exit(0)
}

// `ash tools [refresh]`: show (or rescan) the notable tools ash sees on PATH.
if argv.first == "tools" {
    let list = argv.dropFirst().first == "refresh" ? Tools.refresh() : Tools.available()
    print(list.isEmpty ? "(none detected)" : list.joined(separator: "\n"))
    exit(0)
}

// `ash config ...` subcommand.
if argv.first == "config" {
    let sub = Array(argv.dropFirst())

    func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "on", "true", "1", "yes": return true
        case "off", "false", "0", "no": return false
        default: return nil
        }
    }

    if sub.isEmpty {
        let cfg = Config.load()
        print("daemon:       \(cfg.daemon)")
        print("daemon-timeout: \(cfg.daemonTimeout == 0 ? "none" : "\(cfg.daemonTimeout)m")")
        print("safe-action:  \(cfg.safeAction.label)")
        print("risky-action: \(cfg.riskyAction.label)")
        print("yolo:         \(cfg.yolo)")
        print("context:      \(cfg.context.rawValue)")
        print("metrics:      \(cfg.metrics)")
        print("log:          \(cfg.logExecuted)")
        print("allow:        \(cfg.allow.isEmpty ? "(none)" : cfg.allow.joined(separator: ", "))")
        print("deny:         \(cfg.deny.isEmpty ? "(none)" : cfg.deny.joined(separator: ", "))")
        print("file:         \(Config.fileURL.path)")
        exit(0)
    }

    guard sub.count == 2 else {
        err("ash: usage: ash config <setting> <value>  (see: ash --help)")
        exit(1)
    }
    let (key, value) = (sub[0], sub[1])
    var cfg = Config.load()

    switch key {
    case "daemon":
        guard let on = parseBool(value) else { err("ash: use 'on' or 'off'"); exit(1) }
        cfg.daemon = on
        do { try cfg.save() } catch { err("ash: could not save config: \(error)"); exit(1) }
        print("daemon: \(cfg.daemon)")
        if on {
            print(ShellIntegration.enable())
            Daemon.launch()
        } else {
            print(ShellIntegration.disable())
            Daemon.stop()
        }
    case "daemon-timeout":
        guard let minutes = Int(value), minutes >= 0 else {
            err("ash: use a number of minutes (0 = no timeout)"); exit(1)
        }
        cfg.daemonTimeout = minutes
        do { try cfg.save() } catch { err("ash: could not save config: \(error)"); exit(1) }
        print("daemon-timeout: \(minutes == 0 ? "none" : "\(minutes)m")")
        if Config.load().daemon { Daemon.stop(); Daemon.launch() }  // restart to apply
    case "safe-action":
        guard let a = Action.parse(value) else { err("ash: use run|inject|confirm|copy|print"); exit(1) }
        cfg.safeAction = a
        do { try cfg.save() } catch { err("ash: could not save config: \(error)"); exit(1) }
        print("safe-action: \(a.label)")
    case "risky-action":
        guard let a = Action.parse(value) else { err("ash: use run|inject|confirm|copy|print"); exit(1) }
        cfg.riskyAction = a
        do { try cfg.save() } catch { err("ash: could not save config: \(error)"); exit(1) }
        print("risky-action: \(a.label)")
    case "yolo":
        guard let on = parseBool(value) else { err("ash: use 'on' or 'off'"); exit(1) }
        cfg.yolo = on
        do { try cfg.save() } catch { err("ash: could not save config: \(error)"); exit(1) }
        print("yolo: \(cfg.yolo)")
        if on { err("ash: warning - yolo runs dangerous commands without flagging them.") }
    case "context":
        guard let level = ContextLevel(rawValue: value.lowercased()) else {
            err("ash: use off|light|full"); exit(1)
        }
        cfg.context = level
        do { try cfg.save() } catch { err("ash: could not save config: \(error)"); exit(1) }
        print("context: \(cfg.context.rawValue)")
    case "metrics":
        guard let on = parseBool(value) else { err("ash: use 'on' or 'off'"); exit(1) }
        cfg.metrics = on
        do { try cfg.save() } catch { err("ash: could not save config: \(error)"); exit(1) }
        print("metrics: \(cfg.metrics)")
    case "log":
        guard let on = parseBool(value) else { err("ash: use 'on' or 'off'"); exit(1) }
        cfg.logExecuted = on
        do { try cfg.save() } catch { err("ash: could not save config: \(error)"); exit(1) }
        print("log: \(cfg.logExecuted)")
    case "allow":
        let name = value.lowercased()
        if !cfg.allow.contains(name) { cfg.allow.append(name) }
        do { try cfg.save() } catch { err("ash: could not save config: \(error)"); exit(1) }
        print("allow: \(cfg.allow.joined(separator: ", "))")
    case "deny":
        if !cfg.deny.contains(value) { cfg.deny.append(value) }
        do { try cfg.save() } catch { err("ash: could not save config: \(error)"); exit(1) }
        print("deny: \(cfg.deny.joined(separator: ", "))")
    default:
        err("ash: unknown setting '\(key)'. Try: daemon, daemon-timeout, safe-action, risky-action, yolo, context, metrics, log, allow, deny")
        exit(1)
    }
    exit(0)
}

var actionOverride: Action? = nil
var yoloOverride: Bool? = nil
var daemonOverride: Bool? = nil
var quiet = false
var jsonOutput = false
var rest: [String] = []

// Apply one short flag character. Returns false if unknown. A closure (not a
// local func) so it shares the main-actor isolation of the top-level vars.
let applyShort: (Character) -> Bool = { ch in
    switch ch {
    case "h": printUsage(); exit(0)
    case "v": print("ash \(version)"); exit(0)
    case "r": actionOverride = .run
    case "i": actionOverride = .confirm
    case "c": actionOverride = .copy
    case "p": actionOverride = .print
    case "n": actionOverride = .copy
    case "y": yoloOverride = true
    case "q": quiet = true
    default: return false
    }
    return true
}

for a in argv {
    switch a {
    case "--help": printUsage(); exit(0)
    case "--version": print("ash \(version)"); exit(0)
    case "--run": actionOverride = .run
    case "--inject": actionOverride = .inject
    case "--confirm": actionOverride = .confirm
    case "--print-and-copy": actionOverride = .copy
    case "--print": actionOverride = .print
    case "--dry-run": actionOverride = .copy
    case "--yolo": yoloOverride = true
    case "--no-yolo": yoloOverride = false
    case "--quiet": quiet = true
    case "--json": jsonOutput = true
    case "--daemon": daemonOverride = true
    case "--no-daemon": daemonOverride = false
    default:
        // Single or combined short flags: -q, -p, -qp, -iy, etc. Only when every
        // character is a known flag; otherwise it's part of the request text.
        let body = a.dropFirst()
        if a.first == "-", a.count >= 2, body.allSatisfy({ "hvripnyqc".contains($0) }) {
            for ch in body { _ = applyShort(ch) }
        } else {
            rest.append(a)
        }
    }
}
let request = rest.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
guard !request.isEmpty else {
    printUsage()
    exit(1)
}

// MARK: - Get a Plan, via daemon or in-process

let cwd = FileManager.default.currentDirectoryPath
let cfg = Config.load()
let useDaemon = Config.useDaemon(cliOverride: daemonOverride)

// Gather local environment context (directory, git, project type, tools) so the
// model grounds its command in reality instead of guessing. All local; nothing
// leaves the machine.
let contextBlock = Context.gather(cwd: cwd, level: cfg.context)

let interpretStart = Date()
let interpretation: Interpretation
do {
    if useDaemon {
        interpretation = try await Daemon.requestPlan(request: request, context: contextBlock)
    } else {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            err("ash: the on-device model is unavailable (\(reason)).")
            err("ash: enable Apple Intelligence in System Settings, then try again.")
            exit(2)
        }
        Interpreter.warmUp()
        interpretation = try await Interpreter.plan(for: request, context: contextBlock)
    }
} catch {
    err("ash: could not interpret request: \(error)")
    exit(1)
}
let elapsed = Date().timeIntervalSince(interpretStart)
let plan = interpretation.plan

// MARK: - Decide: run it, or show + copy

let command = plan.command.trimmingCharacters(in: .whitespacesAndNewlines)
guard !command.isEmpty else {
    err("ash: the model did not produce a command.")
    exit(1)
}

let yolo = yoloOverride ?? cfg.yolo

// Safe to auto-run only if positively recognized as read-only or additive.
// Anything else is "flagged"; we surface a reason whenever it is.
let assessment = Safety.assess(command, extraSafe: cfg.allow, extraDanger: cfg.deny)
let flagged = !assessment.isSafe
let dangerReason = assessment.reason ?? "this may modify files or system state"

// --json: emit the structured plan and exit, with no side effects.
if jsonOutput {
    struct Out: Encodable {
        let command: String
        let risky: Bool
        let readonly: Bool
        let explanation: String
        let reason: String?
    }
    let out = Out(command: command, risky: flagged, readonly: assessment.isSafe,
                  explanation: plan.explanation, reason: assessment.reason)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(out) { print(String(decoding: data, as: UTF8.self)) }
    exit(0)
}

// Risk drives action selection unless yolo suppresses it.
let risky = flagged && !yolo
let action = actionOverride ?? (risky ? cfg.riskyAction : cfg.safeAction)

// Set by the shell wrapper (`ash init`); when present, inject hands the command
// off to the shell to load at the prompt.
let injectFile = ProcessInfo.processInfo.environment["ASH_INJECT_FILE"]

func logIfEnabled() {
    if cfg.logExecuted { History.record(command: command, cwd: cwd, flagged: flagged) }
}

// Narration (suppressed by --quiet).
if !quiet {
    print(Style.dim("» \(plan.explanation)"))
    print("  \(Style.bold(command))")
    if flagged {
        let suffix: String
        switch action {
        case .run: suffix = "running anyway"
        case .inject: suffix = injectFile != nil ? "loaded at your prompt" : "press enter to run"
        case .confirm: suffix = "will ask first"
        case .copy, .print: suffix = "not run"
        }
        print(Style.yellow("  \u{26A0} \(dangerReason) - \(suffix)."))
    }
    if cfg.metrics {
        var line = String(format: "%.1fs", elapsed)
        if let tokens = interpretation.tokens { line += " \u{00B7} \(tokens) tokens" }
        print(Style.dim("  \(line)"))
    }
    // Nudge toward the daemon when running in-process and it isn't enabled.
    if !useDaemon && !cfg.daemon && Hints.due("daemon") {
        print(Style.dim("  tip: turn on the daemon for faster responses: ash config daemon on"))
    }
}

switch action {
case .print:
    if quiet { print(command) }  // bare command, useful for piping

case .inject:
    if let injectFile {
        // Hand the command to the shell wrapper to load at the prompt.
        try? command.write(toFile: injectFile, atomically: true, encoding: .utf8)
    } else if isatty(STDIN_FILENO) == 1 {
        // No shell integration installed: offer to run it (in a subshell) or
        // copy it, so we never clobber the clipboard without asking.
        FileHandle.standardError.write(Data("  enter to run, c to copy, esc to skip: ".utf8))
        let key = Runner.readKey()
        print("")
        switch key {
        case "\r", "\n":
            logIfEnabled()
            if !quiet { print(Style.green("  running...")) }
            exit(Runner.execute(command))
        case "c", "C":
            Runner.copyToClipboard(command)
            if !quiet { print(Style.cyan("  copied to clipboard.")) }
        default:  // esc or any other key
            if !quiet { print(Style.dim("  skipped.")) }
        }
    } else if quiet {
        print(command)  // non-interactive: emit the bare command for piping
    }

case .copy:
    Runner.copyToClipboard(command)
    if quiet { print(command) }
    else { print(Style.cyan("  copied to clipboard. Paste to run it yourself.")) }

case .confirm:
    guard isatty(STDIN_FILENO) == 1 else {
        // No terminal to prompt at: copy instead of silently running.
        Runner.copyToClipboard(command)
        if !quiet { print(Style.cyan("  not a terminal; copied to clipboard instead.")) }
        exit(0)
    }
    FileHandle.standardError.write(Data("  run this? [y/N] ".utf8))
    let answer = (Swift.readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    if answer == "y" || answer == "yes" {
        logIfEnabled()
        if !quiet { print(Style.green("  running...")) }
        exit(Runner.execute(command))
    } else {
        if !quiet { print(Style.dim("  skipped.")) }
    }

case .run:
    logIfEnabled()
    if !quiet { print(Style.green("  running...")) }
    exit(Runner.execute(command))
}
exit(0)
