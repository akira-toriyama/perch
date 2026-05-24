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
│                IPC observer for --reload / --quit       │  app
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
│     (AX enumerate     │         │   Source             │
│      + AXPress)       │         │                      │
│   HotkeyMonitor       │         │   (no real AX;       │
│     (Carbon hotkey)   │         │    feeds canned      │
│   KeyTap              │         │    elements)         │
│     (CGEventTap for   │         │                      │
│      keyDown capture) │         │                      │
│   OverlayWindow       │         │                      │
│     (NSPanel)         │         │                      │
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
hotkey shift+space  (or `perch --activate` over DNC)
  │
  ▼
Controller.activate()
  │
  ├─ source.enumerate()                  ← AX walk in Adapter
  │                                        (PerchCore stays AX-free)
  ▼
Labeler.assign(elements, alphabet,
               prioritiseCenter,
               screenSize) → [Hint]      ← pure logic, fully tested
  │
  ▼
overlay.show(hints) { resolved in        ← installs KeyTap
    source.press(id: resolved.element.id)   (CGEventTap),
}                                           orderFront panel,
  │                                         returns immediately
  ▼  user types "as"  (KeyTap swallows the keys; perch is
  │                    NEVER frontmost, so the target app
  │                    keeps focus)
  ▼
Labeler.resolve(hints, "as") → Hint
  │
  ▼
source.press("1234:7") ─→ AXUIElementPerformAction(_, kAXPressAction)
                          (focus is still where it was —
                           the press lands without a focus dance)
```

Every clickable element gets a stable id within one enumeration
(`"\(pid):\(seq)"`). The adapter keeps a side-table
`[id: AXUIElement]` so `press(id:)` can look the live AX handle
up at dispatch time. The id is *not* stable across enumerations
— the side-table is cleared at the top of every `enumerate()`.

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

## CLI surface (M1)

| Flag | Mode | Purpose |
|---|---|---|
| *(none)* | server | run the daemon (hotkey loop) |
| `--debug` | server | mirror logs to stderr too |
| `--validate` | standalone | parse `~/.config/perch/config.toml`, exit 0/2 |
| `--doctor` | standalone | health check; exit 0/1 |
| `--activate` | client | show hint overlay now (CLI mirror of the hotkey) |
| `--cancel` | client | dismiss the overlay if showing |
| `--reload` | client | tell running daemon to re-read config |
| `--quit` | client | terminate running daemon |
| `--status` | client | dump active hotkey + last activation |
| `--help` | standalone | show help |

Client commands (`--activate`, `--cancel`, `--reload`, `--quit`)
talk to the running daemon via `DistributedNotificationCenter`
(notification name `com.perch.app.control` — deliberately
distinct from the bundle id so the bundle id can change without
breaking clients). Refuse with exit 3 if no daemon is running.
`--activate` / `--cancel` exist so external triggers (Karabiner,
skhd, Raycast script commands) can drive hint mode without giving
up perch's built-in Carbon hotkey, and so shell-script triggers
are cheap.

`--status` is one-way the other direction: DNC can't reply, so
the daemon maintains a small status file at `/tmp/perch.status`
that `--status` reads.

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

## Roadmap

- **M1** *(current)* — native AppKit / SwiftUI apps only.
  Single-screen overlay, vim-style hint pills, AXPress dispatch,
  CGEventTap key capture (focus-preserving), CLI activation.
- **M2** — multi-monitor refinement (panel per screen, hint
  pills clamped to their owning screen).
- **M3** — additional roles (treat `kAXChildren`-less custom
  views as labelable when they expose `kAXPressAction`).
- **M4** — scroll mode (separate hotkey activates "type a hint
  to scroll that element" instead of clicking).
- **M5+** — Chrome / Electron support via per-backend adapters
  (a `PerchAdapterChrome` would converse with Chrome via its
  WebDriver-style protocol; Electron via the Chromium AX
  shim). Out of scope for MVP.

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
