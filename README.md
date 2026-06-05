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
| `--menu` | client | enter menu-search mode — fuzzy-match every menu bar item (deep / hidden commands incl.); pick with `1-9` |
| `--windows` | client | enter cross-app window switcher — fuzzy-match every window across every running app; `1-9` raises the window and activates its owning app |
| `--emoji` | client | enter emoji picker — fuzzy-match a curated emoji table by name; `1-9` types the glyph at the caret (Unicode injection — no pasteboard write) |
| `--grid` | client | enter coordinate grid — divide the screen into labeled cells, type a label to warp the cursor + left-click via synthetic `CGEvent` (AX-bypass fallback for Figma canvas / Photoshop / custom-drawn UI) |
| `--rgrid` | client | enter recursive grid — each label drills into the chosen cell up to `[grid].max-depth` levels (default 3, ≈ pixel precision on 4K). `space` clicks at current cell center; `Backspace` pops one level |
| `--nudge` | client | enter arrow-nudge cursor mode — arrows move cursor 1/10/100/edge px (modifier-stepped), `space` clicks + exits. The last-mile precision after `--grid` or `--rgrid` |
| `--drag` | client | enter keyboard drag — nudge to A, press `d` to grab (mouseDown), nudge to B, press `d` again to release (mouseUp). For drag-and-drop, splitter resize, reorder, etc. |
| `--vision` | client | enter Vision-OCR hint mode — Apple Vision text recognition on the main display, every visible word becomes a hint. Requires the Screen Recording grant. Use when AX is blind AND grid is too coarse (Figma layer panel labels, web canvas text). |
| `--cancel` | client | dismiss whichever mode is up (hint / scroll / search / regional / menu / windows / emoji / grid / rgrid / nudge / drag / vision) |
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
| `d` / `Ctrl+d` | scroll down half a screen |
| `u` / `Ctrl+u` | scroll up half a screen |
| `Ctrl+f` | scroll down a full screen |
| `Ctrl+b` | scroll up a full screen |
| `<digits>` | count prefix for the next motion (`5j` = 5 notches, `12k` = 12 up) |
| `gg` | jump to top |
| `Shift+g` | jump to bottom |
| `esc` (or the configured cancel key) | exit scroll mode |
| any other key | exit + let the key through |

The count prefix is capped at 200 so a typo (`999999j`) can't
pin the daemon. Count is consumed on motion fire, cleared on
Esc / unmapped key, and applied to `j` / `k` / `d` / `u` /
`Ctrl+f` / `Ctrl+b`. `gg` / `Shift+g` consume any pending count
but don't multiply (no useful "go to top 5 times"). Plain `d` /
`u` are kept as aliases for the vim canonical `Ctrl+d` /
`Ctrl+u`.

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

### Menu-search mode

`perch --menu` enters a `--search` variant whose target set is
**every menu bar item** in the frontmost app, recursively. Matches
are rendered as a Spotlight-style vertical list (menu items have
no on-screen position until macOS opens the menu, so per-item pill
placement doesn't apply).

Use it to reach deep / hidden commands by name without mousing
through the menu:

- Safari `Develop > Empty Caches` → type `"empt"` → press `1`
- Xcode `Editor > Refactor > Rename` → type `"rename"`
- System Settings sidebar items, app menus that need 3 levels of
  hover to reach — all surface in one keystroke + 1-9 pick.

Action-mode modifiers behave as in `--search`: Cmd-1 copies the
menu path, Shift-1 opens its context menu, Alt-1 focuses without
firing, Cmd+Shift-1 fires + re-enters menu mode for chaining.

Each pill shows the AX-bound keyboard shortcut on the right
(e.g. `1  File > Quit  ⌘Q`) when one exists — a Superkey-style
learning loop: discover the native shortcut while picking the
menu item with `1-9`. Set `[overlay].show-shortcuts = false`
in `config.toml` to hide.

### Grid mode (AX-bypass)

`perch --grid` is the explicit fallback for UIs that hint mode
**can't see**: Figma canvas, Photoshop, Logic, web `<canvas>`,
custom-drawn views. Instead of asking the AX layer where the
clickables are, perch divides the screen into a `[grid].cols ×
[grid].rows` grid (default 12×8) and labels each cell with the
same alphabet hint mode uses.

| Key | Effect |
|---|---|
| `<label>` | warp cursor to cell center + left click |
| `Shift+<label>` | warp + right click |
| `Cmd+<label>` | warp only (no click) — set up the cursor for `--drag` |
| `Cmd+Shift+<label>` | left click + re-enter grid for chained operations |
| `esc` | exit silently |

Dispatch is **synthetic `CGEvent` mouse events**, not AX — the
cursor WILL visibly jump on click. That's the accepted trade-off
for reaching AX-invisible UI. Hint mode (`shift+space` /
`--activate`) remains the snappy, no-cursor-jump default; reach
for `--grid` only when hint mode can't help.

For pixel-precise targeting, **recursive grid** (`perch --rgrid`)
drills into the picked cell instead of clicking immediately, up
to `[grid].max-depth` levels (default 3). On a 4K display three
drills lands the cursor inside a ~5px region.

| Key | Effect (in `--rgrid`) |
|---|---|
| `<label>` | drill into the chosen cell (until depth budget runs out, then click) |
| `space` / `Enter` | "good enough, click here" — terminal click at the current cell center |
| `Backspace` | pop one level (return to parent grid) |
| `Shift` / `Cmd` / `Cmd+Shift` modifiers | same action mapping as `--grid` — applied at click time |
| `esc` | exit silently |

### Arrow-nudge cursor (last-mile precision)

`perch --nudge` is the cursor-movement complement to `--grid` /
`--rgrid`. After grid mode lands the cursor close to the target,
nudge mode walks it the rest of the way with arrow keys.

| Key | Effect |
|---|---|
| `←` `↑` `↓` `→` | move cursor 1 px (precision tweak) |
| `Shift+arrow` | 10 px (small step) |
| `Alt+arrow` | 100 px (medium step) |
| `Cmd+arrow` | jump to the edge of the screen union |
| `space` / `Enter` | left click at cursor + exit |
| `Shift+(space\|Enter)` | right click + exit |
| `Cmd+(space\|Enter)` | middle click + exit |
| `esc` | exit without clicking |
| any other key | exit + let through |

There's **no overlay** — the cursor is the visual feedback. If
you're not sure you're in nudge mode, `perch --status` confirms.

Ctrl is intentionally NOT bound to a step size; Ctrl+arrow is
reserved for macOS Mission Control / Spaces shortcuts.

### Drag mode (keyboard-driven drag-and-drop)

`perch --drag` performs UI drag operations that aren't reachable
through hint mode — Finder column resize, Safari tab reorder,
drag-to-select-text, NSSplitView drag, drag-to-reorder lists.

| Phase / Key | Effect |
|---|---|
| **`.positioning`** (cursor free) | |
| `arrow` (1/10/100/edge px via Shift/Alt/Cmd) | move cursor toward A |
| `d` | **grab** — fire `mouseDown` at current cursor → `.dragging` |
| `Esc` | exit silently (no drag started) |
| **`.dragging`** (button held) | |
| `arrow` | move cursor toward B + post `mouseDragged` so the receiving app updates drop-target highlight |
| `d` / `space` / `Enter` | **release** — fire `mouseUp` + exit |
| `Esc` | **safety release** — fires `mouseUp` first, then exits (don't strand a `mouseDown`) |

Pre-position the cursor with `--grid` / `--rgrid` for a coarse
jump, then `--drag` to perform the actual operation; nudging
inside drag mode tunes the start / end points.

### Vision-OCR hint mode

`perch --vision` is the **last AX-bypass layer**, complementing
`--grid`. Where grid picks coordinates by labelled cells, vision
picks by **what the text says**: Apple Vision recognises every
visible string on the main display, perch labels each, and a
label pick warps the cursor + clicks at the recognised centroid.

Use when:

- Figma layer panel labels (AX is opaque)
- Web `<canvas>` text (Slides, Maps, in-browser editors)
- Image text in a PDF / screenshot viewer
- Game UIs / non-AppKit chrome

Requires the **Screen Recording grant**: System Settings →
Privacy & Security → Screen Recording → enable perch. Without
it `CGDisplayCreateImage` returns nil and the overlay dismisses
silently. First invocation prompts.

**Latency**: 100-400ms per invocation on Apple Silicon (one
screen capture + one Vision request, no per-keystroke
re-capture). Slow compared to hint mode (<30ms) but acceptable
for the deliberate fallback.

For v1, the dispatch supports left / right click, Cmd-click,
Shift-click, double / triple click via the same chord verbs
hint mode uses. `.copyTitle` / `.revealInFinder` /
`.speakTitle` are deferred — vision has no AX target so URL /
file / spoken-text source data isn't available.

### Window switcher

`perch --windows` enters a `--search` variant whose target set is
**every window across every running app**. Labels read
`"<App> — <Window Title>"` (`(min)` annotation for minimised
windows); matches render as the same Spotlight-style vertical
list as `--menu`. Press a digit:

- `1` raises that window AND activates its owning app
  (`AXUIElementPerformAction(kAXRaiseAction)` +
  `NSRunningApplication.activate`).
- `Cmd-1` copies the full `"App — Window Title"` to the
  pasteboard.
- `Cmd+Shift-1` fires + re-enters window mode for chaining
  (raise five windows in a row without re-pressing the flag).

Where `Cmd+Tab` shows one tile per app and Mission Control needs
visual scanning, `--windows` lets you reach any specific window
by name in one keystroke + digit.

### Chord-suffix action mode

Optional vim-style alternative to the modifier-based action map
(issue #57). After a bare-modifier hint resolve, perch can hold
the press briefly and route through a chord suffix instead:

| Chord | Action |
|---|---|
| `,c` | copy title (same as `Cmd+<label>`) |
| `,o` | reveal in Finder (file-URL elements only) |
| `,u` | copy URL (link / file elements) |
| `,s` | speak title via `AVSpeechSynthesizer` |
| `,m` | synthetic **Cmd-click** at the element center (open link in new tab, etc.) |
| `,h` | synthetic **Shift-click** (extend selection in multi-select lists / text ranges) |
| `,d` | synthetic **double-click** at the element center (word-select in text, "open" in Finder) |
| `,t` | synthetic **triple-click** (line / paragraph select) |
| `,g` | **nested grid** — instead of clicking, subdivide the picked element with a grid (M5+); small elements fall back to AXPress |

Default is **off** — set `[chord].leader = ","` in
`config.toml` to opt in. With chord mode on:

- Plain `<label>` still fires `.press` after `timeout-ms`
  (default 600ms) — no behaviour change beyond the slight wait.
- `<label>,c|o|u|s` fires the chord action.
- `Esc` during the chord wait aborts the press entirely.
- `Cmd+<label>` / `Shift+<label>` / `Alt+<label>` /
  `Cmd+Shift+<label>` still work as today — chord is a
  modifier-less alternative, not a replacement.

`,m` / `,h` (M4-ε) cross the AX-bypass carve-out: the cursor
visibly jumps to the element and a `CGEvent` mouse-click with
the modifier flag fires. `AXPress` doesn't honor modifiers, so
this is the only way to reach "Cmd-click to open in new tab"
through hint mode.

### Emoji picker

`perch --emoji` enters a `--search` variant whose target set is
a **curated emoji name table** (≈250 entries: faces, hands,
hearts, animals, food, weather, common symbols). Type the
name; matches render in the same Spotlight-style vertical
list as `--menu`. Press a digit:

- `1` types that emoji at the focused field's caret. Dispatch
  uses `CGEvent.keyboardSetUnicodeString` (same approach the
  macOS built-in picker uses), so perch **never writes to the
  pasteboard** — your clipboard history stays clean.
- `Cmd-1` copies the glyph to the pasteboard instead (your
  explicit ask).
- `Cmd+Shift-1` types + re-enters the picker (insert several
  emoji in a row without re-pressing the flag).

The table is intentionally curated — the long tail of CLDR
(≈3700 entries) is rarely typed by name; niche emoji are
easier to reach via the system picker (`Ctrl+Cmd+Space`).
File an issue to add an entry you typed and didn't find.

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
filtered to frame >= `[regional].min-width` × `min-height` (default
200×100 points; both knobs are individually configurable and clamp
to >= 0). `kAXPressAction` is **not** required (regional picks are
typically copy / focus).

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
perch --dump-regions             # list containers `--regional` would label
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
