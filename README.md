# perch

**English** · [日本語](README.ja.md)

Keyboard-driven UI navigator for macOS. Press a global hotkey,
type a two-letter label, click anything — no mouse, no trackpad.

> Native Mac apps (AppKit / SwiftUI) only — Chrome / Electron are
> out of scope for the MVP.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![MIT](https://img.shields.io/badge/license-MIT-green)

## How it works

1. Press the hotkey (default: `shift+space`).
2. Every clickable element in the frontmost app gets a hint pill
   labeled with one or two letters — home-row keys (`asdf jkl;`)
   first, biased toward the center of the screen.
3. Type the label. perch fires `AXUIElementPerformAction` on the
   matching element. No synthetic clicks, no focus jumps.
4. Esc to cancel; type a non-matching letter to dismiss.

Roles covered out of the box: `Button`, `MenuItem`, `Link`,
`Tab`, `CheckBox`, `RadioButton`, `PopUpButton`, `TextField`,
`SearchField`, `TabGroup`, `MenuButton`. Edit
[`config.toml`](config.toml) to add or trim.

## Install

```sh
brew install akira-toriyama/tap/perch
curl --create-dirs -o ~/.config/perch/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/perch/main/config.toml
perch                              # start the daemon
# grant Accessibility on the first run
```

Or build from source:

```sh
git clone https://github.com/akira-toriyama/perch
cd perch
./setup-signing-cert.sh            # persistent TCC identity (once)
./run.sh                           # builds Perch.app and launches
```

## Configuration

`~/.config/perch/config.toml` is the only thing perch reads.
perch never writes to it.

```toml
[hotkey]
combo = "shift+space"            # also: ctrl+alt+j, cmd+f1, ...

[labels]
alphabet = "asdfjklghqweruiopzxcvbnm"
prioritise-center = true         # closest-to-center element gets 'a'

[overlay]
background = "#fde047"           # hint pill bg (hex)
foreground = "#1f2937"           # hint pill text
font-size = 14                   # 8..32
dim = 0.25                       # 0..0.6  — black overlay alpha

[behavior]
auto-click-on-unique = true      # fire as soon as one candidate remains
roles = ["Button", "MenuItem", "Link", "Tab", ...]
exclude-apps = []                # bundle IDs perch ignores
```

Reload after edits: `perch --reload` (or just save — perch
watches the file for changes when running as a daemon).

## CLI

| Flag | Mode | Purpose |
|---|---|---|
| *(none)* | server | run the daemon |
| `--debug` | server | mirror logs to stderr too |
| `--validate` | standalone | parse `~/.config/perch/config.toml`, exit 0/2 |
| `--doctor` | standalone | health check (AX, config, daemon, hotkey) |
| `--reload` | client | tell running daemon to re-read config |
| `--quit` | client | terminate running daemon |
| `--status` | client | dump active hotkey + last activation |
| `--help` | standalone | show help |

Exit codes: 0 = ok · 1 = `--doctor` red · 2 = bad flag /
invalid config · 3 = client cmd with no running daemon.

## Development

```sh
swift build                      # compile (CommandLineTools works)
swift test                       # tests — needs Xcode
./run.sh                         # build release → launch Perch.app
./stop.sh                        # kill every running instance
```

Architecture: hexagonal Core / Adapter / App split (see
[docs/architecture.md](docs/architecture.md)). Same shape as
[stroke](https://github.com/akira-toriyama/stroke) and
[facet](https://github.com/akira-toriyama/facet).

Commit convention: gitmoji + Conventional Commits
([docs/commit-convention.md](docs/commit-convention.md)).
Enable the local hook:

```sh
git config core.hooksPath scripts/hooks
```

## License

MIT — see [LICENSE](LICENSE).
