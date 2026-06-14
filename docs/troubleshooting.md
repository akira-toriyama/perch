# Troubleshooting

Catalogue of bug signatures we've actually hit + the fix. If you're
seeing one of these, you're probably one PR / config change away
from green.

## `perch daemon --quit` succeeds but a daemon is still running

There's probably a **second daemon left over from an earlier
debug session**. `./stop.sh` greps for both `Contents/MacOS/perch`
and `.build/.*/perch` patterns — run it. Verify with
`pgrep -lf perch`.

Two daemons fighting over the same DNC channel was the cause of
the "duplicate IPC" traces we hit early in M1 (every `--activate`
appearing twice in the log).

## Hint pills appear in empty areas of the screen / outside the focused window

Six different fixes landed for this class of bug; the union of
them is the current filter chain. If you see it AGAIN, this is
the diagnostic order:

1. **Re-run with the latest build.** PRs #10-#16 each fixed a
   slice — `git pull && ./run.sh` to make sure you're not
   testing a cached old binary.
2. **Read the `bounds` line.** `grep "ax: bounds" /tmp/perch.log
   | tail -1`. If `filter=(0,0 N×M)` covers the whole screen
   when the visible window is smaller, the AX/CG bounds got
   misreported and the filter passed every element. The
   `visibleFrame` intersection should have clamped it; if it
   didn't, the user might be on a setup where the menu bar is
   auto-hidden or the Dock is set to "always show on" some
   unusual edge.
3. **Run `perch ax --dump`.** If it lists elements whose frames
   are clearly outside the focused window, the AX tree itself
   is reporting bogus positions (Electron with stale layout
   cache, fullscreen apps with embedded sub-windows). For
   per-app tuning, add a `[behavior."<bundle-id>"]` section
   (issue #37) — raise `min-size`, narrow `roles`, or set
   `auto-click-on-unique = false` for that app alone. Adding
   the bundle to `[behavior].exclude-apps` remains the
   nuclear option (no hints at all in that app).

## Empty pill-shaped frosted rectangles at the bottom of the screen

Mirror image of the labeled pills at the top — bug signature is
that for every label visible at row Y, there's a label-less
frost at row `screenHeight - Y`. The cause is a Y-axis mismatch
between the painter's coords (top-left, isFlipped) and the
blur layer's coords (bottom-left, default CALayer).

This was the PR #16 fix — `OverlayCanvas.layoutPills()` now flips
each pill rect when handing it to the mask path. If a regression
shows the same signature, the suspect is a NEW thing being added
to the mask layer (a search-header strip, a scroll indicator,
etc.) without the flip. See CLAUDE.md → Overlay → "blur-mask
coordinate system" constraint.

## "ax: front=com.apple.loginwindow" in the log

The OS briefly handed loginwindow the frontmost role — usually
during a screensaver wake or a fast user switch. perch's
enumerate returns 0 hints and the overlay never shows.
**Self-resolving** once the user's app gets focus back; not a
perch bug. The log line is here to make it loud-enough-to-trust:
if you see it during normal use, the OS is in a transient state.

## "keytap: tapCreate failed (missing Accessibility?)"

What it says — `CGEvent.tapCreate` returned nil. Two causes:

1. **Accessibility not granted to this binary.** `perch config --doctor`
   should already show `✗ Accessibility: NOT granted`. Grant in
   System Settings → Privacy & Security → Accessibility. If
   you're running `.build/debug/perch` directly, the grant is
   keyed to that exact binary path — every rebuild reinvalidates
   it. Use `./run.sh` (release Perch.app) for sustained
   testing — the bundle id stays stable.
2. **Another tap holds the slot.** Rare — only happens with
   misbehaving keyboard remappers (Karabiner with a bad rule,
   Hammerspoon with a hot-reload bug). `pgrep -lf` for those
   and restart them.

## "tapDisabledByTimeout" or "tapDisabledByUserInput" in the log

The KeyTap had a slow callback and the OS disabled it. perch's
trampoline re-enables on the next event automatically (the
`CGEvent.tapEnable(tap:, enable: true)` call inside the callback);
if it didn't, you'd see hint mode stop responding to keys after
~100ms of CPU pressure. The log is here so a "hint mode froze
once" report has the cause.

## The hotkey doesn't fire at all

Run `perch config --doctor` first.

- `✗ Accessibility` → grant it.
- `✓ Daemon: running` AND no `controller: --activate received`
  in the log when you press the hotkey → another app is binding
  the same combo. Rebind via `[hotkey].active` to something else
  (`ctrl+alt+space`, `cmd+f1`) and run `perch daemon --reload`.
- `✗ Daemon: not running` → `./run.sh` (dev loop) or
  `open Perch.app` (brew install) to launch.

## Pills draw, but pressing the label fires the wrong action

Likely cause: the user typed a label with a modifier held by
accident, which selected an action mode that isn't `.press`. The
mapping is:

- `Shift + label` → right-click (AXShowMenu)
- `Cmd + label`   → copy AXTitle to clipboard
- `Alt + label`   → AXFocus only (no press)
- `Ctrl + label`  → cancel hint mode (system shortcut takes
  precedence, not a perch action)

Documented in [architecture.md](architecture.md) → "Action modes".
If the user wants modifier-held label to behave like a bare
press, they need to release the modifier before typing the
label.

## "ax: enumerated 0 hint(s)" but the page clearly has clickable elements

Web-shell apps (Cursor, VSCode, Slack) sometimes have their AX
tree paused (when the WebContents is suspended, e.g. background
tab). Bring the window forward, give it focus, type one
character into it (anything to wake the AX subsystem), then try
shift+space again. If the count is still 0, run `perch ax --dump`
to confirm whether the issue is enumeration-side or label-side.
