# ash - the agentic shell

**Type what you want. ash writes the command.**

```console
$ ash list the 5 biggest files here
» Lists the 5 largest files in the current directory.
  du -ah . | sort -rh | head -n 5
  running...
  1.2G  ./video.mov
  340M  ./archive.zip
  ...
```

ash turns plain English into the right shell command using an on-device Apple
Intelligence model. Safe, read-only commands run automatically. Anything risky
is shown and copied to your clipboard so you stay in control. It runs entirely
on your Mac, so nothing you type ever leaves the machine.

## The problem

You know what you want the computer to do. You just can't always remember the
exact incantation. Was it `find . -mtime -7` or `-ctime`? Does `tar` use `-z`
here? What is the BSD flag for `stat`? So you stop, open a browser, search,
copy a half-right answer from a forum, and paste it back.

Cloud AI assistants can write the command, but to do it well they need to see
your files, your directory layout, your git state. Sending all of that to a
remote server is a real privacy and security cost, and it means an API key, an
account, a subscription, and a network round-trip on every request.

ash removes both problems at once.

## Why it is safe: everything stays on your Mac

ash uses Apple's on-device Foundation Models. There is no server, no API key,
no account, and no telemetry. Your request, your filenames, and your git state
are read locally, handed to a model running on your own machine, and never sent
anywhere.

That on-device design is not just a privacy nicety. It is what lets ash be
genuinely useful: it can feed the model real context about your directory and
tools precisely because that context never leaves your laptop. A cloud tool
would have to upload your file listing to match it.

Running model-written commands still deserves caution, so ash is conservative by
default:

- It auto-runs a command **only** if it positively recognizes every part as
  read-only or harmlessly additive (`ls`, `grep`, `find`, `git status`,
  `mkdir`, and similar).
- Anything else, including anything it does not recognize, is shown and copied
  for you to run yourself, never executed silently.
- A hard denylist always blocks auto-run of destructive or privileged commands
  (`rm`, `sudo`, `dd`, redirection that clobbers files, and more).

You can tighten or relax this to taste. See [Safety model](#safety-model).

## Install

### Homebrew (recommended)

```sh
brew install dboeke/tap/ash
```

This builds ash from source on your machine, so the binary is never quarantined
and runs immediately with no "downloaded from the internet" warning.

### Signed download

Grab the binary from the [latest release](https://github.com/dboeke/ash-cli/releases/latest).
It is signed with a Developer ID certificate and notarized by Apple, so it runs
without any Gatekeeper warning.

```sh
unzip ash-0.1.0-macos-arm64.zip
install -m 0755 ash /usr/local/bin/ash
```

### From source

```sh
git clone https://github.com/dboeke/ash-cli.git
cd ash-cli
swift build -c release
cp .build/release/ash /usr/local/bin/ash
```

### Requirements

- A Mac with Apple Silicon.
- macOS 26 or newer, with Apple Intelligence enabled in System Settings.
- For building: the Swift 6 toolchain (Xcode or the Command Line Tools).

## Usage

```sh
ash <whatever you want to do>
```

By default, safe commands run and risky ones are shown and copied. A few
examples:

```sh
ash show me what changed in git today
ash find every python file modified this week
ash how much disk is the logs folder using
ash delete all files starting with tmp_     # shown + copied, not run
```

### Actions

Override what ash does with the command it writes:

```
ash -r   <request>   # run it
ash -i   <request>   # show it, ask y/n, run if yes
ash -pc  <request>   # show and copy, do not run (alias: -n)
ash -p   <request>   # show only
ash -y   <request>   # run even if it looks dangerous (prints a warning first)
ash -q   <request>   # no narration; just run, or print the bare command
ash --json <request> # print the plan as JSON and exit
```

Short flags combine, so `ash -qp count the files here` prints just the command.

### Context awareness

Before each request, ash gathers local signals so the model writes commands
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
few seconds. Turn on a warm background daemon for roughly one-second responses:

```sh
ash config daemon on
```

When enabled, ash adds a one-line hook to your shell startup file so the daemon
is warm in every new terminal. It is fully user-space: no login item, no system
approval, no background-item notification. It idles out after 30 minutes and
respawns on demand. Turn it off with `ash config daemon off`, which also removes
the hook.

## Safety model

ash auto-runs a command only when it positively recognizes every part as
non-destructive: read-only inspection (`ls`, `cat`, `find`, `grep`, `git
status`, with mutating forms like `find -delete` and `sed -i` excluded) or
additive creation (`mkdir`, `touch`, which only add reversible things).

Everything else defaults to being shown and copied, not run. The worst case is
you paste a command yourself rather than ash running something unexpected.

ash does not try to predict whether a command needs `sudo`. A command that lacks
permission simply fails with no effect, which is harmless. The genuine danger is
an explicit `sudo`, and that is on the denylist that always blocks auto-run,
along with `rm`, `dd`, `mkfs`, `>` redirection, command chaining, disk and power
operations, `curl`, `wget`, `git push`, and more.

Extend either list yourself:

```sh
ash config allow kubectl     # treat a command as safe to auto-run
ash config deny  terraform   # always flag commands containing this
```

`yolo` mode runs everything, while still printing the danger reason first:

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
ash config safe-action  run|confirm|copy|print     # default: run
ash config risky-action run|confirm|copy|print     # default: copy
ash config context      off|light|full             # default: full
ash config yolo         on|off                      # default: off
ash config log          on|off                      # default: on
ash config allow <command>
ash config deny  <pattern>
```

## How it works

1. ash gathers local context (directory, git, project type, available tools).
2. It asks the on-device model for one shell command plus a risk judgement,
   using guided generation so the output is structured, not free text.
3. A deterministic allowlist, independent of the model, decides whether the
   command is safe to auto-run.
4. Safe commands run in your current directory. Risky ones are shown and copied.

## License

MIT. See [LICENSE](LICENSE).
