# ash - project status

Last updated: 2026-06-13

## What this is
`ash` ("agentic shell"): a Swift CLI that interprets natural-language requests
into shell commands using Apple's on-device Foundation Models. Low-risk commands
run automatically; risky ones are shown + copied to clipboard for the user to run.

## Key decisions
- **Backend:** Apple Foundation Models framework (on-device ~3B model). Chosen
  over Ollama/MLX for zero-install, lowest latency, no per-call cost. Verified
  available on this machine (macOS 27, Swift 6.3.2).
- **Language:** Swift (single native binary, direct framework access, no IPC bridge).
- **Latency reality:** language choice is irrelevant to speed; model inference
  dominates. Warm inference ~1.3-1.8s; cold per-process model load ~3-4s.
- **Daemon:** opt-in via config (default off), per user request. `ashd` holds a
  warm session; `ash` talks to it over a unix socket and auto-spawns it.
  Resolution: CLI flag > ASH_DAEMON env > config file > default(off).

## Architecture (Sources/ash/)
- `main.swift` - arg parsing, `config`/`launch`/`__daemon` subcommands, orchestration, output.
- `Plan.swift` - `@Generable` Codable struct: command, risky, explanation.
- `Interpreter.swift` - stateless model wrapper; cwd passed per request so the
  daemon can serve any directory. Greedy decoding + anti-hallucination
  guardrails + 14 few-shot examples. `warmUp()` loads model; `plan(for:cwd:)`.
- `Safety.swift` - ALLOWLIST gate: `assess()` auto-runs only read-only OR
  additive-create (mkdir/touch) commands (find/sed/awk/git special-cased) + a
  denylist (`dangerReason`). Honors user allow/deny from config. Model's risky
  flag is advisory only. NOTE: create is treated as safe (reversible); we do NOT
  predict permission/sudo needs - a non-sudo perm failure is harmless, explicit
  sudo is denylisted.
- `Action.swift` - enum run|confirm|copy|print; `parse()` accepts aliases.
- `History.swift` - append-only audit log of executed commands (~/.config/ash/
  history.log). `ash history [N]` tails it.
- `Context.swift` - gathers per-request env context (dir listing, git branch +
  status, project markers, tools) into a prompt block. ContextLevel off/light/
  full. Client-side (daemon can't see user's cwd); sent over wire.
- `Tools.swift` - scans $PATH (no subprocess) for notable CLIs, caches to
  tools.json. `ash tools [refresh]`. Feeds "Available tools" into the prompt.
- `Runner.swift` - execute via /bin/zsh, pbcopy clipboard.
- `Daemon.swift` - unix-socket server (`serve`) + client (`requestPlan`) +
  `launch` (instant idempotent spawn) + `stop`. Lifetime flock on `ashd.lock`
  guarantees a single daemon; pid file at `ashd.pid`.
- `Config.swift` - ~/.config/ash/config.json load/save + daemon resolution.
- `ShellIntegration.swift` - detect shell from $SHELL, add/remove a marker-block
  startup snippet (zsh/bash/fish). `ASH_SHELL_RC` overrides target file.

## Daemon startup model
- Lazy: first `ash` call (or first `ash launch`) spawns `ashd`; idle-exits after
  30 min; re-spawns on next use.
- `ash config daemon on` writes a `# >>> ash startup >>>` block to the shell rc
  so `ash launch` runs on every new terminal (warms even the first call).
- DECIDED AGAINST launchd LaunchAgent (2026-06-13). On macOS 13+ a LaunchAgent
  registers a visible "background item" (notification + System Settings entry
  under Login Items & Extensions), which is unwanted friction for a lightweight
  CLI. The shell-rc hook is fully user-space: no approval, no notification, no
  system registration, and it warms exactly when a terminal opens (the only
  place ash is used). Only thing given up is non-terminal warming, which ash
  doesn't need.

## Verified working
- Low-risk auto-run (`ls -lt`), high-risk clipboard (`rm -rf foobar*` blocked).
- Config toggle, daemon cold (5.1s) and warm (1.7s) paths, idle timeout.
- `ash launch` 17ms; 8 concurrent launches -> exactly 1 daemon (lock works).
- Shell integration enable/idempotent/disable against a temp rc.
- Improved prompt: previously-failing "count lines in swift files" now correct.

## Known limitations / next steps
- ~3B model still occasionally drops a step (e.g. "how many files" -> `ls -1`
  instead of `ls -1 | wc -l`). Could add more "how many" few-shot examples.
- No tests yet. No release build/install script beyond README instructions.
- Daemon is single-threaded serial (fine: inference is serialized anyway).
- launchd LaunchAgent: decided against (see Daemon startup model). Not building.
- DONE (2026-06-13): all five - confirm tier, audit log, user allow/deny,
  -q/--quiet, --json. Plus safety refinement (create=safe).
- DONE (2026-06-13): context-awareness (Context.swift/Tools.swift) + BSD/macOS
  syntax rules + tool detection + filename quoting rule. Big quality win:
  "run the tests" off-context -> wrong grep; full-context -> `swift test`.
  Measured: context level has NO consistent latency impact (within model noise),
  so default = full. Wire protocol now sends context block instead of cwd.
- Still open: multi-candidate pick (show 2-3 options to choose from).

## Actions & config model (added 2026-06-13)
- Action enum run|confirm|copy|print. copy=show+clipboard; print=show only;
  confirm=show+ask y/n+run (non-tty falls back to copy).
- Defaults: safeAction=run, riskyAction=copy, yolo=false, logExecuted=true,
  allow=[], deny=[]. All in config.json (decodeIfPresent for forward-compat).
- Per-run flags: -r/--run, -i/--confirm, -pc/--print-and-copy, -p/--print,
  -n/--dry-run(=copy), -y/--yolo, --no-yolo, -q/--quiet, --json.
- Short flags combine (-qp, -iy): parsed char-by-char unless token is an exact
  known flag (-pc) first. applyShort is a closure (main-actor isolation).
- yolo sets risky=false for action selection but danger reason still printed.
- Executed commands logged via History unless logExecuted=false.
