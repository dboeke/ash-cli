# ash - the agentic shell

I have been using computers for fifty years, but almost all of that time was
spent in graphical interfaces. My Unix background is thin. Over the years I
picked up just enough shell and command-line scripting to get the specific jobs
I needed done, and not much more.

So a few times a week I would hit the same wall. I knew exactly what I wanted the
terminal to do, but I could not remember the flags. Was it `find -mtime` or
`-ctime`? Which `tar` options this time? What is the BSD form of `stat`? My habit
became opening ChatGPT or Claude, asking for the exact invocation, copying the
answer, and pasting it into my terminal. It worked, but the friction added up.

ash is what I built to skip that loop. I tell it what I want in plain English and
it writes the command. Read-only commands it just runs. Anything that could
change or delete something it shows me and copies to my clipboard, so I decide
whether to run it.

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

The whole point was to remove friction, and shipping my files off to a server is
its own kind of friction, and its own kind of risk. The cloud tools I was using
to get commands need an account, an API key, and a network round-trip, and to do
a good job they really want to see your directory and your git state.

ash uses Apple's on-device Foundation Models instead. There is no account, no API
key, no telemetry, and no network call. What I type, and the files ash reads to
get the command right, stay on my laptop. Being on-device is also what lets ash
look at real context about your directory and installed tools without that being
a privacy problem, which makes the commands it writes a lot more accurate.

## Will it run something it shouldn't?

That was my first worry too, so ash is cautious by default:

- It runs a command on its own only when it recognizes every part as read-only
  or harmlessly additive (`ls`, `grep`, `find`, `git status`, `mkdir`, and the
  like).
- Anything else, including anything it does not recognize, is shown and copied
  for you to run yourself, never run silently.
- A hard denylist always blocks auto-running destructive or privileged commands
  (`rm`, `sudo`, `dd`, redirection that clobbers files, and more).

You can tighten or loosen this. See [Safety model](#safety-model).

## Install

### Homebrew (recommended)

```sh
brew install dboeke/tap/ash
```

This builds ash from source on your machine, so the binary is never quarantined
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
