# CLAUDE.md

Guidance for working in this repository.

## What this is

`perch` — keyboard-driven UI navigator for macOS. Press a global
hotkey (default `shift+space`); perch labels every clickable
element in the frontmost native app with a short letter
sequence; type a label to click.

**MVP scope is native Mac apps only** — Chrome / Electron / web
views are explicitly excluded (their AX trees are huge and need
backend-specific quirks; see *M2+* in
[docs/architecture.md](docs/architecture.md)).

Architecturally a sibling of
[stroke](https://github.com/akira-toriyama/stroke) /
[facet](https://github.com/akira-toriyama/facet): Swift 6,
macOS 13+, three-layer hexagonal split.

## Build / run

```sh
swift build                  # compile (CommandLineTools works)
swift test                   # tests — needs Xcode (XCTest); fails on CLT
.build/debug/perch --help    # smoke test
.build/debug/perch --validate
./run.sh                     # release → Perch.app, kill prior, launch
./stop.sh                    # kill every running instance
```

Same XCTest constraint as stroke / facet — CommandLineTools alone
can't run tests; let CI cover them. `swift build` is the bar
locally.

`@main enum PerchApp` lives in
[Sources/PerchApp/Main.swift](Sources/PerchApp/Main.swift) (NOT
top-level code in a `main.swift`) so XCTest's executable-target
`@testable import` keeps working once test coverage of the CLI lands.
**Don't reintroduce a `main.swift` file** — same trap as stroke /
facet / ws-tabs.

## Non-obvious constraints — read before editing

### Layer rules (the spine of the project)

- **3 layers are non-negotiable**: `PerchCore` is pure logic
  (CoreGraphics OK, NO AppKit / NO AX / NO Carbon).
  `PerchAdapterMacOS` wraps the OS (AX enumeration, Carbon
  RegisterEventHotKey, NSPanel overlay, AXPress) and is the
  *only* place those types appear. `PerchAdapterTest` is the
  synthetic counterpart for end-to-end labeling tests.
  Crossing layers always means there's a missing protocol.
- **`UIElementSource` is the seam**:
  [Sources/PerchCore/UIElementSource.swift](Sources/PerchCore/UIElementSource.swift)
  declares the protocol; the Controller only ever sees
  `UIElementSource`. Real vs synthetic is picked at app startup.
  Adding a new enumeration strategy (Electron AX adapter,
  CGWindowList fallback, …) means a new `UIElementSource`
  conformer in an Adapter module — never a `#if` in Core.
- **The hint overlay lives in `PerchAdapterMacOS`**, not a
  separate View module
  ([Sources/PerchAdapterMacOS/OverlayWindow.swift](Sources/PerchAdapterMacOS/OverlayWindow.swift)).
  It's the project's only on-screen UI; it's pure AppKit/CG
  rendering driven by `Hint` values from Core. **Don't promote
  it to its own module** unless a second UI surface appears.
  Same reasoning as stroke's `GestureOverlay`.

### The AX-anchored spine — DO NOT regress this

The whole point of perch is that **hint mode acts on the
frontmost app's focused window**. The seam is captured at
`activate()` time, not at hint-press time:

- The frontmost app is resolved via
  `NSWorkspace.frontmostApplication` **once per activation**.
  By the time the user finishes typing, focus may have moved —
  that's intentional: we already have an `AXUIElement` handle
  to the target.
- **`UIElement` is a value type** in
  [Sources/PerchCore/Models.swift](Sources/PerchCore/Models.swift).
  Don't put `AXUIElement` inside it — Core must stay free of
  Application Services types. The adapter keeps a side-table
  (`liveById: [String: AXUIElement]`) keyed by the synthetic
  id and looks it up in `press(id:)`. The serialised
  `UIElement` is what flows through Core.
- **`press(id:)` uses `AXUIElementPerformAction(_,
  kAXPressAction)`** — never simulates a synthetic mouse click.
  AX press is less disruptive (no focus change, no cursor jump)
  and matches the way native UI tests drive controls.
- The id is `"\(pid):\(seq)"`, where `seq` is a monotonic
  counter scoped to **one enumeration**. The side-table is
  cleared at the top of every `enumerate()`, so ids from a
  previous enumeration cannot resolve. This protects against
  the "labeled element vanished while user was typing" race.

### Configuration

- **`config.toml` at the repo root is the source-of-truth
  template**. Users `curl` it into `~/.config/perch/config.toml`
  (see [README.md](README.md) Configuration section).
  **The app only reads it** — never writes, never auto-generates
  an example, never persists runtime overrides. Same policy as
  stroke / facet: the file is the only thing the user has to
  look at to know what perch will do.
- **`[hotkey].active` is the key name**, not `combo`. It mirrors
  the CLI surface (`perch --activate`) — same verb on both sides
  of the seam. Don't rename it back; existing user configs that
  carry the old `combo` key will silently fall back to the
  default hotkey (the typo-tolerance policy below).
- **There is no settings GUI** — by design. Don't propose
  adding NSPanel-based preferences. Memory: facet's
  `config-default-behavior` pattern.
- **All TOML keys clamp out-of-range / unknown values to defaults**
  rather than rejecting. A typo can never break hint mode — the
  key with the typo silently uses the default. `perch --validate`
  is the explicit verification path.

### TOML parser

- **`TOML.parse` is hand-rolled** in
  [Sources/PerchCore/TOML.swift](Sources/PerchCore/TOML.swift)
  — ported from stroke / facet's subset parser. Inline tables
  (`{a=1, b=2}`) and arrays-of-tables (`[[rows]]`) are **not**
  supported because perch's config doesn't need them. Don't add
  parser surface without a real need; the dotted-key form keeps
  the parser ~150 lines.

### Label assignment

- **Single-letter labels never share a prefix with two-letter
  labels.**
  [Sources/PerchCore/Labeler.swift](Sources/PerchCore/Labeler.swift)
  reserves the tail of the alphabet as "prefix letters" used
  only as the first character of two-letter labels. The disjoint
  invariant is what lets the controller fire on `unique-match`
  the moment a key narrows candidates to one — without it,
  typing the first character of a two-letter label could
  momentarily collide with a single-letter label.
- **Center-priority is a layout choice, not a sort.** The
  `prioritiseCenter` flag reorders the *letter assignment* (so
  the closest-to-center element gets `a`), not the input array.
  Tests reach into `Labeler.assign(...)` directly — don't
  pre-sort `elements` to "make the test simpler"; the test
  pins the assignment, not the order.

### Hotkey

- **Hotkey is Carbon `RegisterEventHotKey`**, not
  `NSEvent.addGlobalMonitorForEvents`. NSEvent global monitors
  are passive (no swallow), which would mean `shift+space` would
  also insert a space into the focused text field. The Carbon
  API blocks the event reaching downstream apps — exactly what
  hint mode needs.
- **The C trampoline pulls `self` out of userData via
  `Unmanaged.passUnretained`.** Don't switch to
  `passRetained` — `HotkeyMonitor.deinit` already calls
  `UnregisterEventHotKey` and `RemoveEventHandler`, so the
  trampoline's lifetime is bound to the owning object.
- **`HotkeyMonitor` is `@unchecked Sendable`** and `callback`
  is `@Sendable`. Swift 6's strict checker can't see that
  Carbon dispatches the handler on the main thread; the
  callback hops to `MainActor` explicitly via `Task { @MainActor in ... }`.

### Overlay

- **`NSPanel` with `[.borderless, .nonactivatingPanel]`**, not
  `NSWindow`. A non-activating panel doesn't steal focus, so the
  frontmost app remains key and `AXUIElementPerformAction` lands
  on the right window when the user resolves a hint. Don't
  switch to `NSWindow` "to enable proper key handling" — it
  breaks the press dispatch.
- **Two-layer canvas**:
  [`OverlayCanvas`](Sources/PerchAdapterMacOS/OverlayWindow.swift)
  holds an `NSVisualEffectView` (`.hudWindow`, `.behindWindow`)
  at the bottom and an `HintPainter` on top. The blur layer's
  `CAShapeLayer` mask is rebuilt every layout pass to a path
  covering only the current pill rects — so the frost is bound
  to the pills, not the whole screen. Ported wholesale from
  stroke's `GestureOverlay` two-layer pattern.
- **Pill style**: 10pt corner radius via
  `NSBezierPath(roundedRect:xRadius:yRadius:)` (not layer-level
  `cornerRadius`, which clips poorly under HiDPI scaling). 1pt
  hairline border at white α=0.18 for idle; 2pt accent border
  + `NSShadow` glow (blur 7pt, accent α=0.5) for the matched
  pills once the user starts typing. Monospaced semibold 14pt,
  12 × 9pt padding.
- **Scale-in animation**: 150ms `0.85 → 1.0`, ease-out cubic
  (`1 - pow(1-p, 3)`). Re-layouts every 1/60s while elapsed
  < 150ms so the blur mask scales in lockstep with the painter
  — otherwise the frost briefly extends past the visible pill
  border. Opt-out via `[overlay].anim-enabled = false`.
- **Miss flash**: a keypress that matches no label is held in
  `typed` so the user sees which letter went unmatched, then
  the overlay flashes red for 200ms before dismissing. Drives
  `flashThenCancel` in OverlayWindow. Same opt-out knob as
  scale-in.
- **Accent colour**: `[overlay].accent` accepts `"system"` (the
  user's macOS accent — `NSColor.controlAccentColor`) or a
  `#rrggbb` literal. Anything else falls back to `"system"`
  silently per the typo-tolerance policy.
- **Keyboard capture uses a `KeyTap` (CGEventTap)**, not
  `NSEvent.addLocalMonitorForEvents`. The first attempt at this
  module used the local monitor + a transient
  `NSApp.activate(...)` to make our process key while the overlay
  was up. That worked for capturing keys but moved focus AWAY
  from the underlying app — the user reported it as a "focus
  jumped out from under me" feel, especially right after AXPress
  (caret was no longer where they expected). The CGEventTap
  approach intercepts keys system-wide AND swallows them
  (return `nil` from the callback) without ever activating
  perch, so the underlying app stays key throughout. See
  [Sources/PerchAdapterMacOS/KeyTap.swift](Sources/PerchAdapterMacOS/KeyTap.swift).
  **Don't reintroduce `NSApp.activate` + local monitor** — the
  whole point of the daemon is to be invisible until the user
  finishes typing a label.
- **Cancel key is configurable** via `[hotkey].cancel`
  (default `"esc"`). The overlay resolves the name → keycode
  through `HotkeyMonitor.keyCode(for:)`; unknown names silently
  fall back to Esc. Modifiers in the cancel key aren't
  supported on purpose — using a bare key keeps the cancel
  surface separate from the activation hotkey.
- **Cancel key cancels; non-letter keys cancel; non-matching
  letter cancels.** All three paths take the same `onCancel()`
  branch. Don't try to be "helpful" by treating non-letter keys
  as no-ops — silent input is the worst UX in a modal overlay
  (user types `J`, gets nothing, has no idea why).
- **Modifier-held letters select an action mode**, not cancel.
  Cmd / Alt / Shift held during the resolving keystroke route
  the resolution through `HintAction` (`.copyTitle` / `.focus` /
  `.rightClick` respectively) instead of the default `.press`.
  `actionFor(flags:)` in
  [Sources/PerchAdapterMacOS/OverlayWindow.swift](Sources/PerchAdapterMacOS/OverlayWindow.swift)
  is the single source of truth for the mapping. Ctrl is the
  only modifier that still cancels — reserved for the user's
  own shortcuts (Ctrl-C etc.) so system bindings keep working.

### Logging

- **`Log` lives in `PerchCore`** so both the Adapter and App
  modules can call it without crossing layer rules. Two
  functions: `Log.line` (always on) and `Log.debug` (gated by
  `debugMode`, set from `perch --debug` at startup).
- **Both write to `/tmp/perch.log`**; `--debug` also mirrors to
  stderr so foreground users see events live.
- **Use `Log.debug` liberally** in AX walk hot paths. It costs
  one bool check when disabled. Skip per-recursion logging on
  AX walks of deep windows — the cost adds up even with the
  gate.

### Debugging — how Claude Code observes a running daemon

perch is **headless** (`LSUIElement`, no Dock icon, no menubar
item). The agent cannot "look at the screen" to see what it's
doing — so the daemon is built to be debuggable entirely from
the terminal. The workflow:

1. **Run in the foreground with `--debug`**:
   `.build/debug/perch --debug`. This sets `debugMode = true`
   (enables `Log.debug`) and mirrors every log line to stderr
   in addition to `/tmp/perch.log`.
2. **Tail the log** from a second shell:
   `tail -f /tmp/perch.log`. Single source of observability.
3. **Read the trace.** A successful hint press logs, in order:
   ```
   hotkey: bound shift+space
   ax: front=com.apple.Safari pid=1234
   ax: enumerated 12 hint(s) in com.apple.Safari
   activate: 12 hint(s)
   dispatch: AXPress ok → id=1234:7
   ```
   Each missing line localises the failure to one stage
   (hotkey → AX enumeration → labeling → dispatch).
4. **Check config** with `perch --validate` (exit 0 + summary,
   or exit 2).
5. **Health check**: `perch --doctor` reports Accessibility
   grant, config presence, daemon liveness, hotkey binding,
   and alphabet length.

**AX grant after rebuild:** `swift build` ad-hoc re-signs the
binary, which can drop the Accessibility grant — the symptom is
`AXIsProcessTrusted() = false` in `perch --doctor`. Re-grant in
System Settings, or use the persistent cert
(`setup-signing-cert.sh`) so the grant survives. Use
`pgrep -lf perch` to see what's running and `./stop.sh` to clear
stray instances before relaunching.

### Bundle / signing

- **Bundle id is `com.perch.perch`** (set in
  [Info.plist](Info.plist)). TCC keys the Accessibility grant
  to the code-signing identity, so ad-hoc signing loses the
  grant on every rebuild. [setup-signing-cert.sh](setup-signing-cert.sh)
  creates a persistent self-signed cert so the grant survives
  rebuilds; [package.sh](package.sh) assembles `Perch.app` and
  signs it with that identity (`--dev` → `Perch-dev.app` /
  `com.perch.perch.dev` to co-exist with a Homebrew install
  without TCC collision). Same pattern as stroke / facet.
- **`LSUIElement = true`** — no Dock icon, no menubar item. The
  daemon is intentionally invisible until the hotkey fires.

### CLI surface

- **Flags**: `--debug` (server, verbose), `--validate` /
  `--doctor` / `--help` (standalone), `--activate` / `--scroll`
  / `--cancel` / `--reload` / `--quit` / `--status` (client). Any
  unrecognised flag exits `2` with a stderr message (no silent
  fallback — facet's *Rule of Repair* discipline).
- **`--doctor`** reports Accessibility (`AXTrust.isTrusted()`),
  config, daemon liveness, configured hotkey, and alphabet length.
  Exit 1 if AX fails.
- **`--activate` / `--scroll` / `--cancel` are the CLI mirror
  of the global hotkey**, posted over the same DNC channel as
  `--reload`. They let Karabiner / skhd / Raycast script commands
  trigger hint or scroll mode without giving up perch's built-in
  Carbon hotkey, and make shell-script triggers cheap.
  `--activate` and `--scroll` are symmetric with their entry
  points: a second invocation while the mode is up cancels (same
  path as `--cancel`). Hint and scroll mode are **mutually
  exclusive** — entering one while the other is up tears the
  first one down first so the single KeyTap installs cleanly.
  Don't tee these through a second IPC mechanism —
  `installControlObserver` is the single observer.
- **`--reload` / `--quit` talk to the running daemon over
  Distributed Notification Center** (`com.perch.app.control`,
  see
  [Sources/PerchApp/Control.swift](Sources/PerchApp/Control.swift)
  + `Controller.installControlObserver`) — same pattern as
  stroke / facet. Don't invent a different IPC. They exit `3`
  if no daemon is running.
- **`--status` is one-way the other direction**: DNC can't reply,
  so the daemon rewrites a small status file (`statusPath` =
  `/tmp/perch.status`) on start / reload / each hint press, and
  `--status` just reads it.

## Conventions

- **Commit messages**: gitmoji + Conventional Commits (matches
  stroke / facet). `<:gitmoji:> <type>(<scope>)<!>: <subject>`.
  Enable the local hook: `git config core.hooksPath scripts/hooks`.
- **README is bilingual** ([README.md](README.md) English +
  [README.ja.md](README.ja.md) Japanese). Keep them in sync
  when user-visible behaviour changes — same rule as stroke /
  facet.
- After source edits, **`swift build` must pass** before
  finishing a turn.

## References

External material that informed perch's API / architecture
decisions. Kept here so the rationale survives future
contributors (human or AI) reopening the repo cold.

Subsections ordered **broad → narrow / language-neutral →
language-specific** (memory `external-reference-selection`'s
application-priority rule). Each entry carries
`(reviewed YYYY-MM-DD)` so the freshness lifecycle is visible
at a glance; re-check on any 6+ month gap, refresh the date on
re-confirmation.

### Architecture

- See [facet's CLAUDE.md → References → Architecture](https://github.com/akira-toriyama/facet/blob/main/CLAUDE.md)
  *(reviewed 2026-05-24)* — same hexagonal / Clean Architecture /
  DDD literature applies here. Don't re-list it.
- See [stroke's CLAUDE.md → References](https://github.com/akira-toriyama/stroke/blob/main/CLAUDE.md)
  *(reviewed 2026-05-24)* — the project perch most directly
  mirrors structurally (single-screen overlay + AX dispatch +
  config.toml daemon). Reach there first when a structural
  question arises ("where should X live?").

### macOS / Apple

- [Accessibility API — AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement_h)
  *(reviewed 2026-05-24)* — the API perch hinges on. `AXUIElementCopyAttributeValue`
  walks the AX tree; `kAXChildren` is the recursion edge;
  `AXUIElementPerformAction(_, kAXPressAction)` fires the click.
- [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1462089-axisprocesstrustedwithoptions)
  *(reviewed 2026-05-24)* — the prompt-and-check used by
  `AXTrust.ensureTrusted()`. Note: the option key is referenced
  via the documented string literal (`"AXTrustedCheckOptionPrompt"`)
  rather than the global `kAXTrustedCheckOptionPrompt` symbol
  to avoid Swift 6's "reference to var" diagnostic.
- [Carbon Event Manager — RegisterEventHotKey](https://developer.apple.com/documentation/coreservices/1567440-registereventhotkey)
  *(reviewed 2026-05-24)* — there is no modern AppKit
  equivalent that swallows the underlying keypress. Every
  serious launcher (Raycast, Alfred, Hammerspoon) uses this
  same API. See `HotkeyMonitor.swift`.
- [Quartz Event Services — CGEventTap](https://developer.apple.com/documentation/coregraphics/quartz_event_services)
  *(reviewed 2026-05-24)* — the session-level event tap perch
  uses for **in-overlay** key capture (`KeyTap.swift`). Returning
  `nil` from the callback swallows the event, so a typed hint
  letter doesn't leak into the focused text field. Same
  mechanism stroke uses for its mouse tap; the
  `tapDisabledByTimeout`/`UserInput` self-heal pattern carries
  over.
- [NSPanel — non-activating panel](https://developer.apple.com/documentation/appkit/nspanel/styleemask/nonactivatingpanel)
  *(reviewed 2026-05-24)* — the style mask that lets perch
  paint an overlay without taking focus from the frontmost app
  (so `AXUIElementPerformAction` resolves to the right window).
- [Hardened Runtime / Code Signing](https://developer.apple.com/documentation/security/hardened_runtime)
  *(reviewed 2026-05-24)* — same TCC-Accessibility grant
  concern stroke / facet document. Self-signed persistent
  identity keeps the grant stable across rebuilds.

### Formats / conventions

- [TOML 1.0.0 spec](https://toml.io/en/v1.0.0)
  *(reviewed 2026-05-24)* — what the hand-rolled
  `TOML.parse` approximates. We intentionally support a strict
  subset (no inline tables, no arrays-of-tables). New `.toml`
  features must justify the added parser surface against the
  "≈150-line parser" budget.
- [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
  *(reviewed 2026-05-24)* — type / scope grammar
  `<type>(<scope>)<!>: <subject>`. `docs/commit-convention.md`
  is the project-local rules; CI enforces this via
  `commit-lint.yml`.
- [Gitmoji](https://gitmoji.dev/)
  *(reviewed 2026-05-24)* — the leading emoji on each commit
  (`:sparkles:` feat, `:bug:` fix, `:lock:` security, `:memo:` docs,
  `:test_tube:` test, …). Same convention as stroke / facet —
  mirror that list when in doubt.

### CLI design

- See [facet's CLAUDE.md → References → CLI design](https://github.com/akira-toriyama/facet/blob/main/CLAUDE.md)
  *(reviewed 2026-05-24)* — POSIX utility conventions, Art of
  Unix Programming's *Rule of Repair* (loud + immediate failure,
  never silent fallback), clig.dev. perch's exit-code split
  (0 / 1 / 2 / 3) maps directly there. Don't re-list it.

### Swift / Apple

- [Swift 6 Migration Guide](https://www.swift.org/migration/documentation/migrationguide/)
  *(reviewed 2026-05-24)* — strict-concurrency migration
  patterns (`Sendable`, `@MainActor` isolation, hop patterns).
  Consulted when wiring `HotkeyMonitor`'s Carbon callback to
  `Controller.activate()` (the C trampoline → `Task { @MainActor in ... }`
  hop pattern).
- [Swift Package Manager docs](https://www.swift.org/documentation/package-manager/)
  *(reviewed 2026-05-24)* — `Package.swift` manifest, target /
  product / test-target declarations. Use when adding a module
  or test target (every new `Sources/Perch*` directory needs a
  matching `.target` entry; new `Tests/Perch*Tests` needs a
  `.testTarget`).

### GitHub / CI

- [GitHub Docs (日本語)](https://docs.github.com/ja)
  *(reviewed 2026-05-24)* — primary reference for the bits this
  repo actually touches: `gh` CLI, Actions workflow syntax,
  release drafts, branch protection, fine-grained PAT scoping.
  Mirror of the entry point stroke and facet's CLAUDE.md use.

### Inspiration

- [Vimium (philc)](https://github.com/philc/vimium)
  *(reviewed 2026-05-24)* — the original "f to label every
  link" vim-style navigator (Chrome extension). The disjoint
  single-letter / two-letter prefix invariant in
  `Labeler.swift` is the same trick Vimium uses.
