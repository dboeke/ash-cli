# ash - the agentic shell

I have been using computers for forty years, but almost all of that time was
spent in graphical interfaces. My Unix background is thin. Over the years I
picked up just enough shell and command-line scripting to get the specific jobs
I needed done, and not much more.

So a few times a week I would hit the same wall. I knew exactly what I wanted the
terminal to do, but I could not remember the flags. Was it `find -mtime` or
`-ctime`? Which `tar` options this time? What is the BSD form of `stat`?
Prompting ChatGPT or Claude then copy and pasting it into my terminal is much
faster than reading man pages, but the friction still adds up.

`ash` is what I built to skip that loop. I tell it what I want in plain English and
it writes the command. When the command is "safe" it just runs. Anything that could
change or delete something is injected into my shell prompt, so I read and decide
whether to press Enter.

```console
$ ash list the 5 biggest files here
» Lists the 5 largest files in the current directory.
  du -ah . | sort -rh | head -n 5
  running...
  1.2G  ./video.mov
  340M  ./archive.zip
  ...
```

## It runs on your Mac, not in the cloud

To generate the right command `ash` needs to see what I am working on:
the files in my directory, the kind of project it is, my git branch
and status. I wanted that context to stay on my machine, sending it to someone
else's server on every request is both a real privacy risk and its own kind of
friction.

So `ash` uses Apple's on-device Foundation Models. There is no account, no API key,
no telemetry, and no network call. The context `ash` reads to get a command right
never leaves my laptop. Since there is no longer a privacy tradeoff, `ash` can lean
on it freely, which is a big part of why the commands it writes are accurate.

## Will it run something it shouldn't?

`ash` sorts every command into one of three tiers:

- **Safe** (`ls`, `grep`, `find`, `git status`, `mkdir`, and the like): it just
  runs, because these only read or add reversible things.
- **Risky** (anything it does not recognize as safe, like a `mv` or an unknown
  command): it loads the command at your prompt so you read it and press Enter,
  never run silently.
- **Blocked** (a denylist of the genuinely destructive or privileged: `rm`,
  `sudo`, `dd`, clobbering `>`, and more): it will not load these at your prompt
  or run them on an Enter. It shows the command and makes you press `c` to copy
  it, then paste it yourself. That keystroke is deliberate friction, and your
  clipboard is never touched unless you ask. `yolo` lifts the floor, but even
  then a blocked command still waits for an explicit Enter and never auto-runs.

You can tune all of this, including adding your own commands to the denylist.
See [Safety model](#safety-model).

## Install

### Homebrew (recommended)

```sh
brew install dboeke/tap/ash
```

This builds `ash` from source on your machine, so the binary is never quarantined
and runs immediately with no "downloaded from the internet" warning.

> **On a macOS beta?** Homebrew does not support pre-release macOS (it treats it
> as a Tier 2 configuration) and `brew install` may fail with an Xcode or build
> error, even though the source itself compiles fine. Use the signed download or
> build from source below instead; both work on the beta. This affects only
> people running a macOS beta. On stable macOS the Homebrew install works
> normally.

### Signed download

Grab the binary from the [latest release](https://github.com/dboeke/ash-cli/releases/latest).
It is signed with a Developer ID certificate and notarized by Apple, so it runs
without any Gatekeeper warning.

```sh
unzip ash-*-macos-arm64.zip
install -m 0755 ash /usr/local/bin/ash
```

### From source

```sh
git clone https://github.com/dboeke/ash-cli.git
cd ash-cli
swift build -c release
cp .build/release/ash /usr/local/bin/ash
```

### Shell integration (recommended)

Add this to your `~/.zshrc`:

```sh
eval "$(ash init zsh)"
```

This sets up two things: `ash` can load a command directly at your prompt (see
[Actions](#actions)), and the daemon stays warm in every terminal if you enable
it. It is the same kind of one-line setup as zoxide or starship. Without it, `ash`
still works, but risky commands fall back to a one-key run/copy/skip prompt
instead of loading at your prompt. (bash and fish are supported too: use
`ash init bash` or `ash init fish | source`.)

### Requirements

- A Mac with Apple Silicon.
- macOS 26 or newer, with Apple Intelligence enabled in System Settings.
- For building: the Swift 6 toolchain (Xcode or the Command Line Tools).

## Usage

```sh
ash <whatever you want to do>
```

By default, safe commands run and risky ones are loaded at your prompt. A few
examples:

```sh
ash show me what changed in git today
ash find every python file modified this week
ash how much disk is the logs folder using
ash delete all files starting with tmp_     # loaded at your prompt, not run
```

### Actions

`ash` decides what to do with the command based on risk. **Safe** commands run.
**Risky** ones are loaded right at your shell prompt (with shell integration
installed), so you read it, then press Enter to run it in your own shell or edit
it first. Nothing is copied, and your clipboard is never touched.

If shell integration is not installed, a risky command instead shows a one-key
prompt: press Enter to run it, `c` to copy it, or Esc to skip. So even without
setup, the clipboard is only touched if you ask.

Override what `ash` does for a single command:

```
ash -r   <request>   # run it
ash --inject <req>   # load it at your prompt (the default for risky commands)
ash -i   <request>   # show it, ask y/n, run if yes
ash -c   <request>   # show and copy, do not run (alias: -n)
ash -p   <request>   # show only
ash -y   <request>   # run even if it looks dangerous (prints a warning first)
ash -q   <request>   # no narration; just run, or print the bare command
ash --json <request> # print the plan as JSON and exit
```

Short flags combine, so `ash -qp count the files here` prints just the command.

After each command `ash` prints a small dim line with how long it took and how
many tokens it used, like `1.6s · 1180 tokens`. Hide it with
`ash config metrics off`.

### Context awareness

Before each request, `ash` gathers local signals so the model writes commands
grounded in reality instead of guessing:

- your directory listing, so "open the screenshot" finds the real filename,
- your git branch and status,
- your project type, so "run the tests" becomes `swift test` in a Swift package
  or `npm test` when there is a `package.json`,
- which CLI tools you actually have installed, so it reaches for `rg`, `jq`, or
  `gh` only when they exist.

It also knows macOS ships BSD tools, so it writes `tail -r` instead of `tac`,
`date -v-7d` instead of `date -d`, and `sed -i ''` instead of bare `sed -i`.

All of this is read locally and never leaves your Mac. See your detected tools
with `ash tools`. Tune the depth with `ash config context off|light|full`.

### Speed: the optional daemon

Each `ash` call is a fresh process, and loading the model the first time takes a
few seconds. You will notice this in the timing line. When the daemon is off,
`ash` occasionally reminds you that you can turn it on for roughly one-second
responses:

```sh
ash config daemon on
```

The daemon is warmed by the same `eval "$(ash init zsh)"` shell integration, so
it is ready in every new terminal once you enable it. It is fully user-space: no
login item, no system approval, no background-item notification. It uses only a
few MB of memory (the model itself lives in a shared system service), so by
default it stays running until you stop it or reboot. If you would rather it
exit when idle, set a timeout:

```sh
ash config daemon-timeout 30   # exit after 30 idle minutes (0 = never, default)
```

`ash config daemon off` turns it back off entirely.

## Safety model

A deterministic check (not the model's opinion) sorts each command into a tier,
and the tier picks what `ash` does. The defaults are graduated by how much could
go wrong:

| Tier | What it is | Default | With `yolo` |
| --- | --- | --- | --- |
| **safe** | read-only or additive (`ls`, `grep`, `git status`, `mkdir`; mutating forms like `find -delete` excluded) | run | run |
| **risky** | anything not recognized as safe (a `mv`, an unknown command) | load at your prompt | run |
| **blocked** | denylist of destructive or privileged commands (`rm`, `sudo`, `dd`, `mkfs`, clobbering `>`, command chaining, `git push`, and more) | shown; press `c` to copy, then paste it yourself | load at your prompt |

The blocked tier is the strict one. Per-run action flags like `-r` do not lift
it; only `yolo` does, and even under `yolo` a blocked command is loaded at your
prompt and waits for an explicit Enter. It never auto-runs.

`ash` does not try to predict whether a command needs `sudo`. A command that lacks
permission simply fails with no effect, which is harmless. The real danger is an
explicit `sudo`, which is on the denylist.

You decide where the lines are. The actions are configurable, and you can extend
the allowlist or the denylist (these are adults' tools, after all):

```sh
ash config blocked-action inject   # or run / confirm / print, your call
ash config allow kubectl           # treat a command as safe to auto-run
ash config deny  terraform         # add a command to the blocked tier
```

`yolo` mode demotes every tier one notch, while still printing the danger reason:

```sh
ash -y <request>             # for one command
ash config yolo on           # always (use with care)
```

Every executed command is logged to `~/.config/ash/history.log`. View it with
`ash history`.

## Configuration

All settings live in `~/.config/ash/config.json` and have sensible defaults.
Show them with `ash config`:

```
ash config daemon       on|off                     # warm daemon (default off)
ash config safe-action    run|inject|confirm|copy|print  # default: run
ash config risky-action   run|inject|confirm|copy|print  # default: inject
ash config blocked-action run|inject|confirm|copy|print  # default: copy
ash config context      off|light|full             # default: full
ash config metrics      on|off                      # default: on
ash config yolo         on|off                      # default: off
ash config log          on|off                      # default: on
ash config allow <command>
ash config deny  <pattern>
```

## How it works

1. `ash` gathers local context (directory, git, project type, available tools).
2. It asks the on-device model for one shell command plus a risk judgement,
   using guided generation so the output is structured, not free text.
3. A deterministic allowlist, independent of the model, decides whether the
   command is safe to auto-run.
4. Safe commands run in your current directory. Risky ones are loaded at your
   shell prompt for you to run or edit.

## License

MIT. See [LICENSE](LICENSE).
