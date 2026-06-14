# perch — architecture

perch is a keyboard-driven UI navigator for macOS. Activate via
hotkey → AX-enumerate the frontmost app's focused window → label
every clickable element → type a label to fire
`AXUIElementPerformAction(_, kAXPressAction)`.

The split into **Core / Adapter / App** is the central design
idea (same shape as
[stroke](https://github.com/akira-toriyama/stroke) and
[facet](https://github.com/akira-toriyama/facet)): the pure-logic
core knows nothing about AX, Carbon, or AppKit, so it can be
driven equally by a real `AXUIElementSource` (`PerchAdapterMacOS`)
or by a fixture (`SyntheticUIElementSource` in
`PerchAdapterTest`) in unit tests.

## Layers

```
┌─────────────────────────────────────────────────────────┐
│  PerchApp      @main, CLI argv, Controller wiring,      │
│                IPC observer for daemon --reload /        │
│                daemon --quit                             │  app
└──────────────────────┬──────────────────────────────────┘
                       │
              ┌────────┴────────┐
              │   PerchCore     │  pure logic:
              │                 │   - UIElement / Hint / HotkeyCombo
              │                 │   - Labeler (alphabet assignment)
              │                 │   - TOML parser, PerchConfig
              │                 │   - UIElementSource protocol (the seam)
              │                 │  AppKit / AX / Carbon 非依存
              └────────┬────────┘
                       │
       ┌───────────────┴────────────────────────┐
       │                                        │
┌──────┴────────────────┐         ┌──────────────┴───────┐
│  PerchAdapterMacOS    │         │  PerchAdapterTest    │  adapter
│   AXSource            │         │   SyntheticUIElement │
│     (AX walk, dedup,  │         │   Source             │
│      visible-children,│         │                      │
│      window-bounds    │         │   (no real AX;       │
│      filter,          │         │    feeds canned      │
│      multi-mode       │         │    elements)         │
│      AXPress /        │         │                      │
│      AXShowMenu /     │         │                      │
│      AXFocused /      │         │                      │
│      pasteboard)      │         │                      │
│   HotkeyMonitor       │         │                      │
│     (Carbon hotkey)   │         │                      │
│   KeyTap              │         │                      │
│     (CGEventTap for   │         │                      │
│      keyDown capture) │         │                      │
│   OverlayWindow       │         │                      │
│     (NSPanel, hint    │         │                      │
│      pills + frost)   │         │                      │
│   ScrollMode          │         │                      │
│     (vim-style scroll │         │                      │
│      via wheel evts)  │         │                      │
│   SearchMode          │         │                      │
│     (type-to-filter,  │         │                      │
│      digit picks)     │         │                      │
│   (the only place AX/ │         │                      │
│   AppKit/Carbon/CG    │         │                      │
│   live)               │         │                      │
└───────────────────────┘         └──────────────────────┘
```

`PerchCore` defines `UIElementSource` — the protocol that emits
labelable elements and accepts a `press(id:)` call. The Controller
only ever sees `UIElementSource`. Real vs synthetic is picked at
app startup.

## The activation flow

```
hotkey shift+space  (or `perch overlay --activate` over DNC)
  │
  ▼
Controller.activate()
  │
  ├─ source.enumerate()                  ← AX walk in Adapter,
  │                                        runs the filter chain
  │                                        (see "AX filter chain")
  ▼
Labeler.assign(elements, alphabet,
               prioritiseCenter,
               screenSize) → [Hint]      ← pure logic, fully tested
  │
  ▼
overlay.show(hints) { resolved, action ← installs KeyTap
    in                                   (CGEventTap),
    source.act(id: resolved.element.id, orderFront panel,
               as: action)               returns immediately
}
  │
  ▼  user types "as"  (KeyTap swallows the keys; perch is
  │                    NEVER frontmost, so the target app
  │                    keeps focus. Modifier held during the
  │                    resolving keystroke selects the action
  │                    mode — see "Action modes" below.)
  ▼
Labeler.resolve(hints, "as") → Hint
  │
  ▼
source.act("1234:7", as: action)
  │  .press      → AXUIElementPerformAction(_, kAXPressAction)
  │  .rightClick → AXUIElementPerformAction(_, kAXShowMenuAction)
  │  .focus      → AXUIElementSetAttributeValue(_, kAXFocusedAttribute, true)
  │  .copyTitle  → NSPasteboard.general ← element's title
  ▼
(focus is still where it was — perch never activated, so AXPress
 lands without a focus dance and `.copyTitle` doesn't disturb the
 user's caret)
```

Every clickable element gets a stable id within one enumeration
(`"\(pid):\(seq)"`). The adapter keeps a side-table
`[id: AXUIElement]` so `act(id:as:)` can look the live AX handle
up at dispatch time. The id is *not* stable across enumerations
— the side-table is cleared at the top of every `enumerate()`.

### Action modes

Modifiers held during the *resolving* keystroke pick the action.
Hint enumeration / overlay rendering are identical across modes;
only the dispatch verb at the end differs:

| Modifier | `HintAction` | AX call |
|---|---|---|
| *(none)* | `.press` | `kAXPressAction` (left-click equivalent) |
| `Shift` | `.rightClick` | `kAXShowMenuAction` (context menu) |
| `Cmd` | `.copyTitle` | `kAXTitle` (or `kAXValue`) → `NSPasteboard.general` |
| `Alt` | `.focus` | `kAXFocusedAttribute = true` (focus only, no fire) |
| `Cmd+Shift` | `.pressContinuous` | `kAXPressAction` + Controller re-enters hint mode (continuous-follow) |

`Ctrl` is reserved for the user's own shortcuts (Ctrl-C / system
bindings) and exits hint mode without swallowing the keystroke.

## The labeling algorithm

[Sources/PerchCore/Labeler.swift](../Sources/PerchCore/Labeler.swift)
assigns one or two-letter labels from a configurable alphabet:

- **≤ |alphabet| elements**: single-letter labels in alphabet order.
- **> |alphabet| elements**: reserve the *tail* of the alphabet as
  "prefix letters" — those letters appear **only** as the first
  character of a two-letter label, never as a single-letter label
  in their own right. The single-letter and two-letter spaces stay
  disjoint, so typing the first character of a two-letter label
  can never momentarily collide with a single-letter label.

The disjoint invariant is the same trick Vimium uses (see
References → Inspiration in [CLAUDE.md](../CLAUDE.md)).

With `prioritise-center = true`, elements closer to the screen
midpoint get the earlier (home-row) letters. The reorder only
affects letter assignment, not the input ordering — the test
suite pins this contract.

## AX filter chain

AX trees for non-trivial apps (especially web-shell / Electron
apps like Cursor / VSCode / Slack) routinely contain hundreds of
role-bearing nodes that *aren't* visible click targets — wrapper
divs, scrolled-out content, hidden modal backers. Labeling all
of them gives the user a wall of pills floating over empty
space. `AXSource.enumerate()` composes five filters to whittle
the raw AX tree down to "what's actually on screen and clickable":

1. **`kAXVisibleChildren` walk** — when a container exposes
   `kAXVisibleChildrenAttribute`, recurse through it instead of
   `kAXChildrenAttribute`. Scroll areas / web areas / outlines
   honour the attribute and only return their visible subset,
   so we stop walking through scrolled-out subtrees before per-
   node attribute reads kick in. The walker also tracks whether
   it has crossed into an `AXWebArea`; once it has, the recursion
   depth ceiling lifts from 32 → 64 for the rest of that subtree.
   Chromium / WKWebView trees routinely bury clickable leaves
   40+ levels below the web-area root, well past the native cap
   — keep the cap for the rest of the native UI but relax it
   locally inside web content. Surfaces in the log as
   `ax: web-area entered at depth=N → maxDepth 32 → 64`.
2. **Role allow-list** — only nodes whose `kAXRole` is in
   `[behavior].roles` (Button, MenuItem, Link, Tab, …) survive.
3. **`supportsPress`** — the node must advertise
   `kAXPressAction` or `kAXShowMenuAction`. Eliminates
   role-bearing-but-inert containers that web shells expose as
   "Button" without an actual click path.
4. **`insideWindow`** — the node's frame *centre* must be inside
   the focused window's bounds. The window bounds come from
   `CGWindowListCopyWindowInfo` (Quartz's view of what's on
   screen), intersected with `NSScreen.main.visibleFrame`
   (excludes menu bar + Dock). The latter clamp catches apps
   that over-report their AX window frame to span the full
   screen even when the visually-rendered window is smaller.
5. **`dedupNearOverlaps`** — when several nodes share the same
   top-left (within 8 points), keep the first depth-first hit
   and drop the rest. Either ancestor or leaf fires the same
   AX action, so collapsing the stack is safe.

A diagnostic line lands in `/tmp/perch.log` on every enumerate:

```
ax: bounds cg=(…) ax=(…) → filter=(…)
ax: enumerated N hint(s) in <bundle-id>
ax: de-dup M → N
```

— invaluable when triaging "pills outside / over wrong elements"
reports.

## CLI surface

`Main.swift` is the single source of truth (the recognition loop);
argv tokenizing is now delegated to the shared sill `CLIKit`
tokenizer, while perch keeps its own verb vocabulary. The full
README CLI table is authoritative for end-user copy. The CLI is a
yabai-style domain-verb grammar (`perch <domain> --<verb>
[VALUE]`); each domain takes exactly one verb. The architectural
cut:

| Mode | Domain · verb |
|---|---|
| server | *(no domain)* — run the daemon (hotkey loop) |
| standalone | `config --validate` (exit 0/2) · `config --doctor` (exit 0/1) · `--help` |
| standalone diagnostics | `ax --dump` · `ax --tree` (raw, pre-filter) · `ax --regions` (regional-mode candidates) |
| client (mode entry) | `overlay --activate` · `overlay --scroll` · `overlay --search` · `overlay --regional` · `overlay --menu` · `overlay --windows` · `overlay --emoji` · `overlay --grid` · `overlay --rgrid` · `overlay --nudge` · `overlay --drag` · `overlay --vision` |
| client (control) | `overlay --cancel` · `daemon --reload` · `daemon --quit` · `daemon --show` · `overlay --theme <name>` |

`overlay --theme` takes a space-separated value (`overlay --theme
neon`); passing an empty string (`overlay --theme ''`) clears the
override, and a bare `--theme` with no value is an error. Values
are never `--theme=<name>`. Combining verbs within a domain (e.g.
`daemon --reload --quit`) or using a flag outside its domain exits
2 — no silent fallback; an unknown flag prints a "did you mean
…?" hint. Exit codes: 0 ok / 1 diagnostic check failed
(`config --doctor`, `ax --*` with no AX grant) / 2 usage · bad
flag · invalid config (loud stderr) / 3 daemon precondition
(Rule of Repair: loud + immediate failure, never silent
fallback).

Verbose logging is not a flag: set the `PERCH_DEBUG` env var
(e.g. `PERCH_DEBUG=1 perch`) to mirror logs to stderr and enable
the per-walk trace. The dev launcher sets it; a brew/raw launch
stays quiet.

Client commands all talk to the running daemon via
`DistributedNotificationCenter` (notification name
`com.perch.app.control` — deliberately distinct from the bundle
id so the bundle id can change without breaking clients).
Refuse with exit 3 if no daemon is running. The mode-entry
client flags exist so external triggers (Karabiner, skhd,
Raycast script commands) can drive any mode without giving up
perch's built-in Carbon hotkey, and so shell-script triggers are
cheap. **Every interactive mode is mutually exclusive** — hint /
scroll / search / regional / menu / windows / emoji / grid /
rgrid / nudge / drag / vision — Controller tears down whichever
is active before starting a new one so the single session-level
KeyTap installs cleanly.

`daemon --show` is one-way the other direction: DNC can't reply, so
the daemon maintains a small status file at `/tmp/perch.status`
that `daemon --show` reads.

## Keyboard input — the second seam

While the overlay is up, keyboard input is captured by `KeyTap`
([Sources/PerchAdapterMacOS/KeyTap.swift](../Sources/PerchAdapterMacOS/KeyTap.swift)),
a session-level `CGEventTap`. The earlier design used an
`NSEvent.addLocalMonitorForEvents` + transient `NSApp.activate(...)`
pair, which captured keys but stole focus from the underlying app
— after AXPress the caret blinked in the wrong window. The tap
swallows the typed letters by returning `nil` from its callback
without ever activating perch, so the target window stays key
throughout the hint flow.

Events with `Cmd` / `Ctrl` / `Option` held are intentionally **not**
swallowed: the user can still `⌘Q` the focused app or `⌘Tab`
away with the overlay up. The cancel key is configurable via
`[hotkey].cancel` (default `"esc"`); the overlay resolves the
name through `HotkeyMonitor.keyCode(for:)`.

## Multi-screen + display-coord conversion

The overlay panel covers the **union of every connected
NSScreen** — not just `NSScreen.main` — so a hint over a window
on a secondary display still lands on a canvas pixel. AX
positions arrive in CG global coordinates anchored to the
*primary* display's top-left; the canvas-local mapping is:

```
canvas_x = CG_x − unionFrame.minX
canvas_y = CG_y − (primaryHeight − unionFrame.maxY)
```

When the primary IS the topmost screen the Y offset is 0 and
the formula collapses to the single-screen identity, so the
multi-screen path is a strict superset. The union is
recomputed on every `show()` so a display
disconnect / reconnect between activations is reflected.

### Y-axis gotcha (lesson learned)

`OverlayCanvas` sets `isFlipped = true` so AX top-left frames
map straight to canvas-local coords. The `NSVisualEffectView`
that sits underneath the painter (for the frosted-glass
background) is NOT flipped — its `CALayer` mask uses Y-up from
bottom-left. **When handing pill rects into the mask path,
flip Y explicitly** (`mask_y = canvasHeight − pill.rect.maxY`).
Skipping this conversion is silent: the painter still draws
labels in the correct place, but the frost shows up mirrored
to the bottom of the canvas. PR #16 was the fix; CLAUDE.md
flags the constraint so future contributors don't reintroduce
it.

## Roadmap

All milestones below are **shipped**. Issue numbers link to the
canonical PR(s) on the GitHub project board (`perch roadmap`).

- **M1** — native AppKit / SwiftUI apps, vim-style hint pills
  with frosted-glass styling, AXPress dispatch, CGEventTap key
  capture (focus-preserving), CLI activation, action-mode
  modifiers (Shift / Cmd / Alt + Cmd+Shift continuous-follow),
  scroll mode, search mode, multi-screen support.
- **M2** — additional AX role coverage (treat `kAXChildren`-less
  custom views as labelable when they expose `kAXPressAction`);
  per-app behavior config (#37 — `[behavior."<bundle-id>"]`
  overrides `roles` / `min-size` / `auto-click-on-unique` per
  frontmost bundle, falling through to the global `[behavior]`
  for unset keys).
- **M2+** — Chrome / Electron / WKWebView coverage via the
  Chromium AX shim (#26 / #27): the walker lifts its depth
  ceiling once it crosses into an `AXWebArea`; the Controller
  pre-warms renderer-AX on Chromium app activation (#28) so the
  first hotkey after focus-change sees the populated page tree
  rather than just the browser chrome; `ax --tree` exposes
  the raw tree for diagnosing what AX actually reports for a
  given web shell. #38 generalises the bundle-id allow-list with
  *observation-based discovery*: when the walker encounters an
  `AXWebArea` in a bundle outside `chromiumPrefixes` (Books, Mac
  App Store, Slack notification flyouts, native apps with embedded
  WKWebView marketing panes), the bundle is promoted in-memory
  for the rest of the daemon lifetime so subsequent activations
  get the wake / prewarm path too.
- **M3** — regional hints (#34) — `perch overlay --regional` enters a
  hint-mode variant whose `UIElementSource.enumerateRegions()`
  walks the AX tree with `regionalRoles` (Group / Article /
  Section / SplitGroup / ScrollArea / Outline / Image), a
  200×100 frame floor, and no `kAXPressAction` requirement.
  Same overlay + label-resolution pipeline as hint mode;
  action-mode modifiers apply (Cmd → copyTitle is the headline
  use). `AXUIElementSource` shares the AX walk between hint and
  regional via a `WalkPolicy` struct.
- **M3+** — menu-bar search (#52) — `perch overlay --menu` reuses
  `SearchMode` against `UIElementSource.enumerateMenu()`, which
  walks `kAXMenuBarAttribute` recursively and emits each
  pressable menu item with its full `"File > Save As…"` path as
  the label. Renders matches as a centred vertical list (menu
  items have no on-screen frame until opened — the `.zero` frame
  rules out pill-over-element placement). The `SearchRenderMode`
  enum gates between pills and list at draw time. Companion
  ports: `overlay --windows` (#54, cross-app window switcher),
  `overlay --emoji` (#55, curated emoji picker), `overlay --search`
  fuzzy + synonyms (#53), scroll mode count-prefix + half/full-page
  bindings (#56), chord suffix actions (#57), AX shortcut annotation
  on `overlay --menu` pills (#58).
- **M4** — explicit AX-bypass dispatch family. `overlay --grid` (#66,
  M4-α) divides the screen into a labelled `cols × rows` grid;
  `overlay --rgrid` (#67, M4-β) drills recursively up to `max-depth`
  levels per pick; `overlay --nudge` (#68, M4-γ) is the arrow-key cursor
  walker for last-mile precision; `overlay --drag` (#69, M4-δ) does
  keyboard-driven mouseDown / move / mouseUp. The chord suffix
  family gained modifier-held synthetic clicks (`,m` / `,h` —
  #70, M4-ε), sticky modifiers (#71, M4-ζ), and multi-click
  (`,d` / `,t` — #72, M4-η). Dispatch is synthetic `CGEvent`
  mouse events — the cursor visibly jumps; that's the carve-out
  for reaching AX-invisible UI (Figma canvas, Photoshop, web
  `<canvas>`).
- **M5** — Vision-OCR hint mode (#73): `overlay --vision` runs Apple
  Vision's `VNRecognizeTextRequest` on the main display capture
  and emits one `UIElement` per recognised string. Click is
  synthetic `CGEvent` at the centroid (no AX target). Requires
  the Screen Recording grant; latency 100-400ms on Apple Silicon.
- **M5+** — element-nested grid (#74): the `,g` chord, instead of
  clicking the resolved element, subdivides the element's frame
  with a `GridMode` instance. Small elements (under
  `[grid].nest-min-size`) fall back to AXPress.
- **Visual surface** (PRs #84-98, 2026-06) — theme palette
  (`[overlay].theme` — the shared sill catalog `canonicalThemeNames`
  + `[overlay.themes.<name>]` custom palettes); pill shape; 4 effect
  channels (appear / match
  / unmatch / narrow); neon border; sound; modifier badge
  (off / glyph / action); hot-reload of `~/.config/perch/config.toml`;
  hold-to-peek; per-app effect overrides; `overlay --theme <name>` CLI
  session override; `PerchConfig` sub-struct refactor (PR #89).

## References

- [CLAUDE.md](../CLAUDE.md) — non-obvious constraints to read
  before editing (the side-table-clearing policy, the disjoint
  prefix invariant, NSPanel non-activating-style rationale, …)
- [commit-convention.md](commit-convention.md) — message format
  + release flow
- [stroke's architecture.md](https://github.com/akira-toriyama/stroke/blob/main/docs/architecture.md)
  — same hexagonal pattern, different domain (mouse gestures
  + cursor-anchored window target)
- [facet's architecture.md](https://github.com/akira-toriyama/facet/blob/main/docs/architecture.md)
  — same hexagonal pattern at a larger scope (window manager
  with pluggable backend)
