# Debugging perch

perch is **headless** (`LSUIElement`, no Dock icon, no menubar
item). Every observable signal is either in
[`/tmp/perch.log`](#the-log-file) or in one of the standalone
diagnostic commands below.

## The five-second triage

```sh
perch --doctor           # accessibility, screens, frontmost, log file
perch --dump-ax          # exactly what perch would label right now
perch --dump-ax-tree     # the raw AX tree (pre-filter) of the focused window
tail -F /tmp/perch.log   # live event stream
```

If a bug report has these three outputs attached, 90% of the time
the cause is visible without launching anything else.

## Standalone diagnostic commands

### `perch --doctor`

Health report covering the things that most commonly go wrong.
Every line is bug-report-grade information:

```
perch doctor
  ·  macOS:          Version 15.5 (Build 24F74)
  ✓  Accessibility:  granted
  ✓  Config:         /Users/…/perch/config.toml — hotkey=shift+space, 11 role(s)
  ✓  Daemon:         running
  ·  Hotkey:         shift+space
  ·  Cancel key:     "esc"
  ·  Alphabet:       "asdfjklghqweruiopzxcvbnm" (24 chars)
  ·  Screens:        2 connected
  ·    screen 0:     0,0 5120×2160 (main)
  ·    screen 1:     -1440,-196 1440×900
  ·  Frontmost:      com.google.Chrome (pid 38558)
  ·  Log:            /tmp/perch.log (12345 bytes)
```

Exit 0 if every ✓ is green; exit 1 if any ✗.

### `perch --dump-ax`

Walks the frontmost app's AX tree through perch's full filter
chain and prints each surviving element on one line:

```
perch dump-ax → com.apple.calculator (pid 12345)
found 23 labelable element(s):
    1  Button          (   22,  129   33×  40)  "AC"
    2  Button          (   80,  129   33×  40)  "±"
    3  Button          (  138,  129   33×  40)  "%"
    …
```

**If the element you expected appears in the list:** the bug is in
label assignment or overlay rendering. Continue with `PERCH_DEBUG=1` +
log inspection.

**If the element doesn't appear:** the bug is in the AX walk or
the filter chain. Re-run perch with `PERCH_DEBUG=1` and watch
`/tmp/perch.log` for the per-stage drop reasons (`ax: de-dup M → N`,
the `bounds … → filter=(…)` rect, etc.). When the missing element
sits inside a web view (Chrome / Electron / a WKWebView host), the
next command is the one to reach for — `--dump-ax` only shows
nodes that made it through the role + press-support filters, and
a web area might not be exposing any clickable leaves at all yet.

### `perch --dump-ax-tree`

Walks the focused window's **raw** AX tree depth-first and prints
one line per node — pre-filter, regardless of role or press
support. Shows what AX itself sees before perch decides what to
label:

```
perch dump-ax-tree → com.google.Chrome (pid 38558)
[d=0] Window (3080,  275 1708×1511)  kids=8 vis=8  actions=[Raise]
  [d=1] Group  (3080,  275 1708× 100)  kids=12 vis=12  actions=[·]
    [d=2] Button (3520,  290   40× 40)  kids=0 vis=0  actions=[Press]  "New tab"
    …
  [d=1] Group  (3080,  375 1708×1411)  kids=1 vis=1  actions=[·]
    [d=2] WebArea  (3080, 375 1708×1411)  kids=42 vis=18  actions=[·]  *WEB*  "https://github.com/…"
      [d=3] Group  …
      …
--
nodes: 187  web-areas: 1  depth-clipped: 0
```

The `*WEB*` marker flags AX web-area roots; the walker lifts its
depth ceiling from 32 → 64 once it crosses one (web DOM trees
routinely bury clickable leaves 40+ levels below the root, well
past the native cap).

**If the element isn't anywhere in the raw tree** (no entry, no
ancestor that mentions it): the AX backend is hiding it. Chrome's
renderer accessibility is lazy — first activation of an AX client
on a page can take a beat to populate; for Electron apps the
content area may have to be focused at least once. The fix isn't
in perch's walker. **If the element IS in the raw tree but doesn't
appear in `--dump-ax`:** the filter chain dropped it — usually the
role allow-list (the node's role isn't in `[behavior].roles`) or
press support (the node didn't advertise `kAXPressAction`).

### `perch --validate`

Pure parse check of `~/.config/perch/config.toml`. Exit 0 if it
parses (every clamp / fallback is a "success" — the policy is
"typo can't break the daemon"), exit 2 on a syntactic failure
the parser actually rejects. Useful in `pre-commit` hooks if you
edit the config in version control.

### `perch --status`

Reads `/tmp/perch.status` (the file the daemon writes on every
hotkey / activation / reload). Exit 3 if no daemon is running.

## The log file

Both the agent and the standalone diagnostic commands write to
`/tmp/perch.log`. There are two log levels:

- `Log.line` — always written. Operational events: hotkey
  bound / unbound, daemon start / quit, overlay show / hide,
  every AX enumerate's `bounds` + `enumerated N` lines.
- `Log.debug` — written **only** when the daemon is run with
  the `PERCH_DEBUG` env var set or when `debugMode = true` is set
  on a standalone command. Per-walk decisions, scroll events,
  search-filter steps, etc.

The diagnostic line every AX enumeration emits is the most
important one to know how to read:

```
2026-05-25 09:46:41.328 ax: bounds cg=(3080,275 1708×1511) ax=(3080,275 1708×1511) → filter=(3080,275 1708×1511)
2026-05-25 09:46:41.476 ax: enumerated 83 hint(s) in com.google.Chrome
2026-05-25 09:46:41.476 overlay: union=(0,0 5120×2160) primaryH=2160 screens=1
```

- `cg=…` — what `CGWindowListCopyWindowInfo` reported for the
  topmost normal-layer window of the frontmost app. The Quartz
  ground truth.
- `ax=…` — what AX `kAXPosition`+`kAXSize` reported for the
  same window. For most apps this matches `cg`; for some
  Electron / web-shell apps `ax` over-reports (entire screen).
- `→ filter=…` — the rect actually used for the
  `insideWindow` check. It's the chosen base (cg if available,
  else ax) intersected with `NSScreen.main.visibleFrame` so
  menu bar and Dock are clipped out.
- `enumerated N hint(s)` — count after every filter has run.
- `overlay: union=… primaryH=… screens=N` — overlay panel's
  union frame (covers every connected display), the primary
  display's height (used for CG ↔ canvas conversion), and the
  total screen count. Useful for "pills are nowhere visible"
  reports — confirms perch sees the same screen topology you do.

### Reading a failing trace

The five-stage AX filter chain (visible-children walk → role
allow-list → `supportsPress` → `insideWindow` → `dedupNearOverlaps`)
each leaves a trace:

- `ax: de-dup M → N` — dedup dropped `M − N` elements at the same
  pixel.
- `ax: front=<bundle>` — frontmost app at enumerate time.
- `ax: no frontmost app` — perch saw nothing; usually loginwindow
  during a transition.
- `ax: enumerated 0 hint(s)` — every filter rejected. Most often:
  AX returned no window, or every element was outside the
  `filter=` rect, or none supported `kAXPressAction`.

For the in-window decisions, run with `PERCH_DEBUG=1` and the per-walk
trace shows up via `Log.debug`.

## The dev script

`./run.sh --dev` collapses the "edit Swift → rebuild → relaunch
→ tail log" cycle into one command. Same shape as facet's
`run.sh --dev`:

```sh
./run.sh                   # release Perch.app, single launch (no tail)
./run.sh --dev             # DEBUG Perch-dev.app + tail log (dev loop)
./run.sh --dev --no-tail   # same, skip the tail
```

`--dev` builds a parallel `Perch-dev.app`
(`com.perch.perch.dev`) so its TCC grant doesn't collide with a
brew-installed Perch.app — both can coexist with their own
Accessibility grants. The launched app inherits `PERCH_DEBUG=1`
so the per-walk filter-chain drop reasons land in the log.

## See also

- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — common bug
  signatures + the fix that landed them
- [architecture.md](architecture.md) — what the diagnostic
  fields mean structurally (filter chain, multi-screen,
  Y-flip)
- [CLAUDE.md](../CLAUDE.md) — non-obvious constraints (read
  before editing)
