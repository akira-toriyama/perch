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

# Per-app overrides — change `roles`, `min-size`, or
# `auto-click-on-unique` per frontmost bundle id. Unset keys fall
# through to the global `[behavior]` value.
[behavior."com.google.Chrome"]
min-size = 20                    # declutter 16×16 window-control glyphs
```

Reload after edits: `perch --reload` (or just save — perch
watches the file for changes when running as a daemon).

## CLI

| Flag | Mode | Purpose |
|---|---|---|
| *(none)* | server | run the daemon |
| `--validate` | standalone | parse `~/.config/perch/config.toml`, exit 0/2 |
| `--doctor` | standalone | health check (AX, config, daemon, hotkey) |
| `--activate` | client | show hint overlay now (CLI alternative to the hotkey) |
| `--scroll` | client | enter scroll mode (`j/k/d/u/gg/G`, `esc` to exit) |
| `--search` | client | enter search mode (type text, `1-9` picks a match) |
| `--regional` | client | enter regional mode — label large containers (article / pane / image) instead of every clickable leaf |
| `--cancel` | client | dismiss whichever mode is up (hint / scroll / search / regional) |
| `--reload` | client | tell running daemon to re-read config |
| `--quit` | client | terminate running daemon |
| `--status` | client | dump active hotkey + last activation |
| `--help` | standalone | show help |

`--activate` / `--scroll` / `--cancel` let you bind a different
trigger (Karabiner, skhd, Raycast script command) without giving
up perch's built-in hotkey, or trigger from scripts. Inside the
overlay, `Esc` always cancels — type a non-matching letter to
cancel too.

### Scroll mode

`perch --scroll` (bind it to a hotkey externally for one-key
entry) puts perch into scroll mode and intercepts:

| Key | Effect |
|---|---|
| `j` | scroll down one notch |
| `k` | scroll up one notch |
| `d` | scroll down half a screen |
| `u` | scroll up half a screen |
| `gg` | jump to top |
| `Shift+g` | jump to bottom |
| `esc` (or the configured cancel key) | exit scroll mode |
| any other key | exit + let the key through |

Scroll dispatches via `CGEvent.scrollWheelEvent` against the
focused window, so perch itself stays headless and the scroll
lands wherever the user's caret was.

### Search mode

`perch --search` enters search mode for apps with many
clickables (Xcode, Logic, the System Settings sidebar). Type a
substring of the element's visible title; matching elements get
numbered pills `1` through `9` overlaid on them. Press a digit
to fire the action against that match.

| Key | Effect |
|---|---|
| any letter / number / punctuation / space | append to the query |
| `backspace` | drop the last char |
| `1` … `9` (when there are matches) | activate match #N |
| `Enter` | activate match #1 |
| `esc` (or the configured cancel key) | exit search mode |

The same modifier conventions from hint mode apply: `Shift+1`
right-clicks match #1, `Cmd+1` copies its title, `Alt+1` focuses
it without firing.

A digit typed when the match list is empty (no current matches)
is treated as a query character so you can still search for
"v2" / "API 3" / etc.

### Regional mode

`perch --regional` labels **large containers** (article / pane /
image / sidebar) instead of every clickable leaf — for "select
this article" / "copy this image" / "focus that pane" tasks.

The same labels and modifier conventions from hint mode apply,
just with bigger pills on bigger targets:

- `a` (no modifier) — press the container (rarely useful for
  non-pressable groups)
- `Cmd+a` — **copy the container's title** to the pasteboard
  (the headline use case)
- `Shift+a` — open its context menu
- `Alt+a` — focus it without firing
- `Cmd+Shift+a` — copy + re-enter regional mode (chain copies)

Element selection: `AXGroup` / `AXArticle` / `AXSection` /
`AXSplitGroup` / `AXScrollArea` / `AXOutline` / `AXImage`,
filtered to frame >= 200×100 points. `kAXPressAction` is **not**
required (regional picks are typically copy/focus).

Exit codes: 0 = ok · 1 = `--doctor` red · 2 = bad flag /
invalid config · 3 = client cmd with no running daemon.

### Verbose logging

perch always writes to `/tmp/perch.log`. Start it with the
`PERCH_DEBUG` environment variable set to also mirror every log
line to stderr and enable the verbose per-walk trace:

```sh
PERCH_DEBUG=1 perch
```

The dev launcher (`./run.sh`) sets `PERCH_DEBUG` for you; a
normal/brew launch sets nothing and stays quiet.

## Development

```sh
swift build                      # compile (CommandLineTools works)
swift test                       # tests — needs Xcode
./run.sh                         # debug → Perch-dev.app + log tail (dev loop)
./run.sh --no-tail               # same, skip the tail
./run.sh --release               # release → Perch.app (pre-publish verify)
./stop.sh                        # kill every running instance
perch --doctor                   # health check (accessibility, screens, …)
perch --dump-ax                  # list AX elements perch would label
perch --dump-ax-tree             # raw AX tree, pre-filter (web triage)
```

Architecture: hexagonal Core / Adapter / App split (see
[docs/architecture.md](docs/architecture.md)). Same shape as
[stroke](https://github.com/akira-toriyama/stroke) and
[facet](https://github.com/akira-toriyama/facet).

Triaging a bug? Start with
[docs/debugging.md](docs/debugging.md) and
[docs/troubleshooting.md](docs/troubleshooting.md) — both list
the diagnostic commands, the log-line format, and the bug
signatures we've already seen.

Commit convention: gitmoji + Conventional Commits
([docs/commit-convention.md](docs/commit-convention.md)).
Enable the local hook:

```sh
git config core.hooksPath scripts/hooks
```

## License

MIT — see [LICENSE](LICENSE).
