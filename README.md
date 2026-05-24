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

### Action modifiers

Hold one of these while typing the resolving label to change the
action:

| Modifier | Action | AX call |
|---|---|---|
| *(none)* | click | `AXPress` |
| **Shift** | right-click / context menu | `AXShowMenu` |
| **Cmd** | copy the element's title to the clipboard | pasteboard |
| **Alt** | focus only — don't fire | `AXFocused = true` |

Cmd-copy is useful for grabbing the visible name of a control
without retyping. Alt-focus is right for text fields you intend
to type into. Ctrl is left alone so system shortcuts (Ctrl-A
etc.) still work — pressing Ctrl while the overlay is up cancels.

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
active = "shift+space"           # also: ctrl+alt+j, cmd+f1, ...
cancel = "esc"                   # dismiss hint mode; bare key, no modifiers

[labels]
alphabet = "asdfjklghqweruiopzxcvbnm"
prioritise-center = true         # closest-to-center element gets 'a'

[overlay]
accent = "system"                # accent for matched pill / typed prefix
                                 # "system" = user's macOS accent; #rrggbb also OK
font-size = 14                   # 8..32 — monospaced semibold
blur-enabled = true              # frosted-glass background per pill
anim-enabled = true              # 150ms scale-in + 200ms red miss-flash

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
| `--activate` | client | show hint overlay now (CLI alternative to the hotkey) |
| `--cancel` | client | dismiss the overlay if showing |
| `--reload` | client | tell running daemon to re-read config |
| `--quit` | client | terminate running daemon |
| `--status` | client | dump active hotkey + last activation |
| `--help` | standalone | show help |

`--activate` / `--cancel` let you bind a different trigger (Karabiner,
skhd, Raycast script command) without giving up perch's built-in
hotkey, or trigger from scripts. Inside the overlay, `Esc` always
cancels — type a non-matching letter to cancel too.

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
