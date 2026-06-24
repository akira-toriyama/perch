# CLAUDE.md

Guidance for working in this repository.

## Terminology

All UI / config / code terminology follows
[`docs/glossary.md`](docs/glossary.md) — use the canonical names
(`PerchCore`, `UIElementSource`, `hint`, `label`, `AX target`,
`action mode`, `HotkeyMonitor`, `KeyTap`, `OverlayWindow`, `pill`,
`AX 5-stage filter chain`, `ScrollMode`, `SearchMode`, …), **not** the
`Don't call it:` synonyms. Adding or renaming a term lands in the
same PR as the code change.

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
.build/debug/perch config --validate
./run.sh                     # debug → Perch-dev.app + log tail (dev loop)
./run.sh --release           # release → Perch.app (pre-publish verify)
./install-cli.sh             # symlink `perch` onto $PATH
                             #   (prefers Perch-dev.app → Perch.app)
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
  (CoreGraphics OK, NO AppKit / NO AX / NO Carbon). Today that
  includes `Config` (the typed view of `~/.config/perch/config.toml`),
  `Theme` (the sill theme **bridge** — `perchThemeSpec` /
  `perchCanonicalThemeName` + perch's translucency / themed-miss
  overlays — plus `PillShape` / AppearEffect / MatchEffect /
  UnmatchEffect / BorderEffect / EffectIntensity / ModifierBadgeStyle),
  `Labeler`, `TOML`, `Models`, `UIElementSource`, `SearchFilter`,
  `EmojiTable`, `Log`. `PerchAdapterMacOS` wraps the OS (AX
  enumeration, Carbon RegisterEventHotKey, NSPanel overlay,
  AXPress, NSSound) and is the *only* place those types appear.
  `PerchAdapterTest` is the synthetic counterpart for end-to-end
  labeling tests. Crossing layers always means there's a
  missing protocol.
- **The static theme catalog comes from `sill`** (plan atelier's
  shared theming library), not a perch-local catalog. `PerchCore`
  depends on sill's pure, AppKit-free `Palette` module (`ThemeSpec` /
  `paletteFor` / `FontKind` / `canonicalThemeNames`) — perch is the
  family's "pure twin", proving that module is reusable outside
  facet's View. perch does NOT link `PaletteKit`: the adapter resolves
  the spec to `NSColor`s itself (`HintPainter.resolvePalette`) because
  perch keeps its own `[overlay].accent` override + pill-surface
  treatment (translucency / themed miss / dark-pill `system`). Third-
  party SwiftPM deps stay at zero; the sill dep is first-party and
  pinned (url + `.upToNextMinor`, lockfile committed). To edit sill +
  perch atomically, swap `Package.swift`'s url dep for
  `.package(path: "../sill")`.
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
  id and looks it up in `act(id:as:)`. The serialised
  `UIElement` is what flows through Core.
- **`act(id:as:)` uses `AXUIElementPerformAction(_,
  kAXPressAction)`** for AX-anchored dispatches (hint, regional,
  search, menu, windows). AX press is less disruptive (no focus
  change, no cursor jump) and matches the way native UI tests
  drive controls. **Mouse synthesis carve-out:** the M4 series
  (`overlay --grid` / `overlay --rgrid` / `overlay --nudge` /
  `overlay --drag` and the
  modifier-held click variant) is the explicit AX-bypass — those
  modes have no AX target by definition, so `CGEvent` mouse
  events are the ONLY dispatch path. The cursor WILL visibly
  jump on grid / nudge clicks; that's an accepted trade-off for
  reaching Figma canvas / Photoshop / custom-drawn UI. **Don't
  reach for `CGEvent` in the AX-anchored path** — if you're
  about to add synthetic clicks to hint / search / menu /
  windows, stop and reconsider.
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
  the CLI surface (`perch overlay --activate`) — same verb on both sides
  of the seam. Don't rename it back; existing user configs that
  carry the old `combo` key will silently fall back to the
  default hotkey (the typo-tolerance policy below).
- **There is no settings GUI** — by design. Don't propose
  adding NSPanel-based preferences. Memory: facet's
  `config-default-behavior` pattern.
- **All TOML keys clamp out-of-range / unknown values to defaults**
  rather than rejecting. A typo can never break hint mode — the
  key with the typo silently uses the default. `perch config --validate`
  is the explicit verification path.
- **Prefer fully-nested TOML when adding new knobs** — every key
  should live under a `[section]` header. A top-level scalar mixed
  with sections looks like an orphan and is the user's stated
  dislike (memory `user-collaboration-style`):

  ```toml
  # 好き — everything under a section
  [foo]
  color = "red"
  length = "short"

  [bar]
  color = "red"
  size = "xl"

  # 嫌い — top-level scalar floating above sections
  color = "red"
  [foo]
  length = "short"
  ```

  This is a *want* / *better*, not a *must* — break it when the
  alternative is clearly worse (a global toggle that has no natural
  section would be one). The reason the rule is loose: TOML allows
  the floating form, and forcing a one-key `[global]` section just
  to satisfy the rule reads as ceremony. When in doubt, group with
  the closest sibling and prefer one extra section over an orphan.
- **Breaking config changes are OK when they buy consistency.**
  The user's repeated stance during the visual-surface wave was
  "破壊的変更OK / 一貫性の方が重要だから" (see memory
  `user-collaboration-style`). Examples that landed by breaking:
  PerchConfig sub-struct refactor (PR #89), `show-modifier-badge`
  Bool → string enum (PR #92/#96), `[overlay.theme.<name>]` →
  `[overlay.themes.<name>]` plural (PR #95). The typo-tolerance
  policy above protects against silent breakage on the OLD key —
  the renamed key falls back to the default + a `Log.line` warning
  pointing at the new name, instead of erroring out. Land breaking
  renames with the warning path in the same PR.
- **`PerchConfig` is grouped into 11 sub-structs** (PR #89):
  `hotkey` / `labels` / `overlay` / `effect` / `border` / `sound`
  / `behavior` / `regional` / `grid` / `chord` / `search` — 1:1
  with TOML sections. Every accessor goes through one of them
  (e.g. `config.effect.match`, `config.behavior.effectiveRoles(...)`,
  `config.grid.maxDepth`). The flat layout was retired after the
  synthesized memberwise-init kept tripping argument-order bugs at
  40+ fields. Each sub-struct has an explicit `public init` so
  field order is no longer load-bearing.
- **`~/.config/perch/config.toml` is watched live** via
  `DispatchSourceFileSystemObject` in
  [`Sources/PerchApp/ConfigWatcher.swift`](Sources/PerchApp/ConfigWatcher.swift)
  (PR #86). Edits to the file fire `Controller.reload(cause: "fs")`
  with a 150ms debounce + atomic-rename re-open. `perch daemon --reload`
  IPC still works as the explicit path. Don't bypass the watcher
  for "convenience" — `daemon --reload` is the manual override.

### TOML parser

- **TOML parsing is delegated to swift-toml-edit's `Toml` module**
  (Sill-1 — the family's one TOML implementation). perch reads its
  config via `Toml.parseFlat` (Config.swift). The former hand-rolled
  `Sources/PerchCore/TOML.swift` (ported from stroke / facet's subset
  parser) was removed when perch moved onto the shared lib — there is
  no in-tree perch parser any more.
- perch's `config.toml` only uses a flat, dotted-section subset, but
  the underlying lib is full TOML 1.0, so there is no local
  "~150-line parser budget" to defend.

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
  [`OverlayCanvas`](Sources/PerchAdapterMacOS/OverlayCanvas.swift)
  holds an `NSVisualEffectView` (`.hudWindow`, `.behindWindow`)
  at the bottom and an `HintPainter` on top. The blur layer's
  `CAShapeLayer` mask is rebuilt every layout pass to a path
  covering only the current pill rects — so the frost is bound
  to the pills, not the whole screen. Ported wholesale from
  stroke's `GestureOverlay` two-layer pattern.
- **`OverlayCanvas` is the shared visual surface** for hint mode
  AND grid mode (PR #87). `PillPlacement` (`.elementTopLeft` vs
  `.elementCenter`) is the only behavioural split — hint pills
  anchor at element top-left, grid pills at cell midpoint. New
  modes that need the same theme / pill-shape / appear / match /
  unmatch / narrow / border / sound surface should instantiate
  `OverlayCanvas(placement:)` rather than rolling their own NSView.
  `SearchMode` is the deliberate hold-out — its query-strip +
  digit-prefixed-label layout doesn't fit the per-element pill
  model, so it keeps its own `SearchCanvas` and only borrows the
  theme palette / font / sound from the shared layer.
- **Effect drivers** (`ParticleDriver`, `GhostDriver`) live in
  their own files since PR #90 and accept a `HintPainter` at init
  for output. The OverlayCanvas only delegates — drivers own the
  simulation state and tick loop. Add new particle-style effects
  by extending `ParticleDriver` or creating a sibling, not by
  growing OverlayCanvas.
- **Pill style baseline**: 10pt corner radius via
  `NSBezierPath(roundedRect:xRadius:yRadius:)` (not layer-level
  `cornerRadius`, which clips poorly under HiDPI scaling). 1pt
  accent-tinted hairline border (α=0.55) for idle; 2pt accent
  border + `NSShadow` glow (blur 7pt, accent α=0.5) for matched
  pills. **Font / padding / shape now flex** under the visual
  surface added in PR #86-93:
  - **Font**: `[overlay].font-size` (clamped 8..32, default 15)
    in the family the resolved spec picks (mono / rounded / system;
    sill's `.menu` renders as system on pills). Resolved once via
    `HintPainter.resolvePalette` — both the painter and
    `OverlayCanvas.pillRect` width-sizing read it, so a custom
    palette's font drives sizing too.
  - **Shape**: `[overlay].pill-shape` (`pill` / `square` /
    `circle` / `underline` / `tag`) — body path resolved in
    `HintPainter.shapeFor(cfg:hint:rect:)`. `.underline`
    suppresses the body entirely.
  - **Palette**: `[overlay].theme` selects from the shared sill
    catalog (`canonicalThemeNames` — terminal / dracula / … + the
    cross-app `chomp` / `rainbow`) or a `[overlay.themes.<name>]`
    custom palette. The default `"system"` keeps
    `NSColor.controlAccentColor` + dark pill tint (historical look).
    `[overlay].accent` overrides the palette accent so users can layer
    a personal highlight on any theme body. See
    [docs/glossary.md](docs/glossary.md) → "theme palette" /
    "custom palette" / "pill shape".
- **Effect channels** (PR #86 / #87 / #93): 4 directions share
  one kind vocabulary (none / fade / explode / drop / rise /
  slide-* / vibrate / fireworks / confetti / random):
  - `[overlay.effect].appear` — entrance (default `pop` = the
    historical 150ms `0.85 → 1.0` scale-in).
  - `[overlay.effect].match` — winning pill on resolve.
    AXPress fires in parallel so click latency is unchanged.
  - `[overlay.effect].unmatch` — layered on the 200ms red flash.
  - `[overlay.effect].narrow` — per-pill exit when typed-prefix
    filters a pill out (PR #93). `.fireworks` / `.confetti`
    silently downgrade to `.fade` here (per-pill particle bursts
    on a dense set would emit hundreds simultaneously).
  - `intensity` (subtle/normal/bold/wild) scales amplitude;
    `duration-scale` (0.1..5.0) scales tempo. The "150ms" /
    "200ms" timings are baselines — both multiply through.
  - Particle drivers live in
    [`Sources/PerchAdapterMacOS/ParticleDriver.swift`](Sources/PerchAdapterMacOS/ParticleDriver.swift)
    and
    [`Sources/PerchAdapterMacOS/GhostDriver.swift`](Sources/PerchAdapterMacOS/GhostDriver.swift),
    extracted out of OverlayCanvas in PR #90.
- **Per-app effect overrides** (PR #92):
  `[behavior."<bundle>"]` accepts `appear-effect` /
  `match-effect` / `unmatch-effect` / `narrow-effect` in
  addition to the AX-walk knobs. `BehaviorConfig.effective*(for:
  fallback:)` resolvers consult per-app first then fall through
  to the global `[overlay.effect]`. OverlayCanvas reads them via
  `effectiveAppear()` / `effectiveMatch()` / `effectiveUnmatch()`
  / `effectiveNarrow()` keyed by `activeBundleID`.
- **Modifier badge** (PR #92): `[overlay].show-modifier-badge`
  is a string enum (`"off"` / `"glyph"` / `"action"`), not a
  bool. PR #96 dropped the bool back-compat — a bare TOML bool
  now logs + falls back to `"off"`. `"action"` paints `⌘ Copy`
  / `⇧ Right` / `⌥ Focus` / `⌘⇧ Chain` so the user reads what
  the resolve will do; `"glyph"` is just `⌃⌥⇧⌘`.
- **Border neon** (PR #91): `[overlay.border]` (`effect` /
  `glow` / `width` / `cycle-seconds`). 30Hz hue tick driven by
  `OverlayCanvas.startBorderCycle` while the overlay is up.
- **Sound** (PR #91):
  [`Sources/PerchAdapterMacOS/SoundPlayer.swift`](Sources/PerchAdapterMacOS/SoundPlayer.swift)
  plays `[overlay.sound].match / unmatch / activate`. Accepts
  macOS system-sound names OR `~/foo.mp3` paths (tilde-expanded
  + AVFoundation-decoded — mp3 / m4a / wav / aiff). Empty /
  `"none"` silences.
- **Theme override (CLI session)** (PR #96): `perch overlay --theme NAME`
  posts a `theme:<name>` IPC; Controller stores
  `themeOverride: String?` and rebuilds the effective config via
  `PerchConfig.withTheme(_:customName:)` on every push to source
  / overlay / sound. Cleared on `daemon --reload` or empty
  `overlay --theme ''`. The one value-taking verb in the CLI
  surface (space-separated, never `--theme=NAME`).
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
  **Cmd + Shift = `.pressContinuous`** — same AX dispatch as
  `.press`, but the Controller re-enters hint mode immediately
  after firing so the user can chain actions (open 5 PRs in a
  row, close 8 notifications, …) without re-pressing the
  hotkey between each. Search mode follows the same mapping —
  Cmd+Shift in `overlay --search` picks the match AND re-enters search
  mode with an empty query for the next round.
  `actionFor(flags:)` in
  [Sources/PerchAdapterMacOS/OverlayWindow.swift](Sources/PerchAdapterMacOS/OverlayWindow.swift)
  is the single source of truth for the hint-mode mapping;
  `SearchMode.fire(_:flags:)` mirrors it — keep them in sync.
  Ctrl is the only modifier that still cancels — reserved for
  the user's own shortcuts (Ctrl-C etc.) so system bindings
  keep working.
- **Chord-suffix action mode (issue #57)** is an opt-in
  alternative to the modifier-based dispatch above. When
  `[chord].leader` is non-empty, a bare-resolve enters
  `OverlayWindow.enterChordWait(hint:)`: the panel orderOuts,
  the KeyTap stays installed, and a `[chord].timeout-ms` timer
  arms. `,c|o|u|s` finalizes with `.copyTitle` /
  `.revealInFinder` / `.copyURL` / `.speakTitle`; timeout or
  any other key finalizes with `.press`; Esc aborts entirely.
  **Default is leader empty → chord mode OFF** so the
  bare-resolve UX stays snappy — opting in is a config-only
  step. The chord state machine lives **only in OverlayWindow
  (hint mode)**; search-mode variants (`overlay --search` /
  `overlay --menu` / `overlay --windows` / `overlay --emoji`) keep
  the modifier-only mapping.
  Don't grow chord into those without a real demand — their
  digit-pick UX (`1-9`) already covers the multi-action pivot
  case.
  New actions are dispatched in `AXUIElementSource.act(...)`:
  `.copyURL` reads `kAXURLAttribute` (NSURL or NSString —
  handle both), `.revealInFinder` does the same and routes
  file-URLs through `NSWorkspace.activateFileViewerSelecting`,
  `.speakTitle` queues an `AVSpeechUtterance` on the instance's
  long-lived `speechSynth`. **Don't make `speechSynth` a local
  var** — utterances stop when the synth deallocates.
- **Panel covers the UNION of every connected NSScreen**, not
  `NSScreen.main.frame`. AX positions arrive in CG global coords
  anchored to the primary display's top-left, so a pill for a
  window on a secondary display has a canvas-local X past the
  main screen's width — if the canvas only covered main, that
  pill would fall off the right edge. The conversion in
  `OverlayCanvas.pillRect(for:)` accounts for both the union
  origin AND the offset between primary-top and union-top:
  `canvas_y = CG_y − (primaryHeight − unionFrame.maxY)`. When
  primary IS the topmost screen the Y offset collapses to 0 and
  we recover the single-screen identity — so the multi-screen
  path is a strict superset.
- **The blur-mask coordinate system is NOT canvas-local — flip Y
  explicitly when crossing into it.** `OverlayCanvas` is
  `isFlipped = true` (top-left origin); the `NSVisualEffectView`
  underneath is NOT, so its `CALayer` mask uses Y-up from
  bottom-left. Passing canvas-flipped pill rects straight into
  the mask path silently mirrors the frost to the bottom of the
  canvas — surfaces as empty pill-shaped rectangles below the
  visible window for every label drawn at the top. `layoutPills()`
  computes `mask_y = canvasHeight − pill.rect.maxY` before adding
  to the mask path. **Don't drop this conversion** unless
  `NSVisualEffectView.isFlipped` becomes overridable (today it
  isn't). Same constraint applies to anything else we ever put
  in the mask layer (scroll-area boxes, search header strip, …).
- **Chromium / Electron renderer-AX is pre-warmed on app
  activation** (`AXUIElementSource.prewarm`). Chrome's renderer
  populates its AX tree asynchronously the first time an AX
  client queries it — without the prewarm the user's *first*
  hotkey after switching to Chrome enumerates only the browser
  shell (no page links / buttons). Controller hooks
  `NSWorkspace.didActivateApplicationNotification` and calls
  `prewarm(pid:bundleID:)` for any Chromium-detected bundle;
  the call is gated by `isWebBearing(_)` (static
  `isChromiumBundle` allow-list ∪ `discoveredWebBundles`),
  idempotent per pid (one-shot per daemon lifetime), and
  performs the minimum AX query needed to register interest
  (focused window + its direct children). Logged as
  `ax: prewarm → <bundle>`. Don't bypass this for native AppKit
  apps — Office apps reroute event handling under
  `AXEnhancedUserInterface` and would slow.
- **WebArea discovery promotes WKWebView hosts** (issue #38).
  Native AppKit apps that embed a WKWebView (Books, Mac App
  Store, Slack notification flyouts, login web views) aren't
  in `chromiumPrefixes`, but they do surface an `AXWebArea`
  the moment the walker descends through them. On the first
  such sighting the bundle is added to
  `discoveredWebBundles` (session-lifetime) so subsequent
  activations get the wake / prewarm path too. Logged as
  `ax: WebArea in non-listed bundle <bid> → promoted` once
  per bundle; the live list is also rewritten into
  `/tmp/perch.status` (`discovered-web-bundles:` line) so
  `perch daemon --show` can show what perch has learned. **Safe to
  extend the Enhanced wake gate this way** — observation-based,
  so Office (no WebArea) never lands there.
- **Manual and Enhanced wake have independent per-pid latches**
  (`wokenPids` / `enhancedPids`). Splitting them is what lets
  WebArea discovery promote a bundle and have the Enhanced
  flip *fire on the next enumerate* — if both shared one latch
  (the original design), the Manual flip on the first
  activation would mark the pid "woken" before discovery
  happened, and the Enhanced branch would then never see the
  promoted state. `clearRendererWake()` reverses Enhanced
  using `enhancedPids` (the pids we actually flipped), not
  `wokenPids`. `prewarm()` updates both latches so a
  subsequent `enumerate()` doesn't double-flip.
- **AX enumeration runs through a 5-stage filter chain** (see
  `docs/architecture.md` → "AX filter chain"):
  visible-children walk → role allow-list → `supportsPress` →
  `insideWindow` (Quartz bounds clamped to visibleFrame) →
  `dedupNearOverlaps`. Each stage exists because of a specific
  failure mode reported on web-shell apps; don't remove a stage
  without checking the corresponding bug. Diagnostic
  `ax: bounds … → filter=…` + `ax: de-dup M → N` lines are
  Log.line (always on) so users can attach `/tmp/perch.log` to
  bug reports without re-running with `PERCH_DEBUG=1`.

### Scroll mode + search mode + regional mode + menu mode + window switcher + emoji picker + grid mode + vision hints

- **`ScrollMode` and `SearchMode` are parallel to
  `OverlayWindow`** — each owns its own KeyTap + (for search)
  NSPanel, and they're **mutually exclusive** with hint mode.
  `Controller.cancel()` tears down whichever is active. They
  exist because hint mode's "type a label to click" UX has hard
  limits: scrolling can't be expressed as a label-pick, and
  apps with hundreds of clickables (Xcode, Logic) outrun the
  alphabet.
- **Scroll mode synthesises `CGEvent.scrollWheelEvent` events**
  against the focused window. Perch never takes focus, so the
  scroll lands where the user's caret was. `gg` / `Shift+g` go
  top / bottom by firing 20 large notches (macOS clamps at the
  scroll-view bounds — over-shooting is safe and avoids
  per-app AX glue).
- **Search mode caches the AX enumeration on entry** and filters
  in memory per-keystroke rather than re-walking. Digit
  resolution (`1-9` → match[N-1]) is **gated on a non-empty
  match list** so digits remain typable as query characters
  when there are no matches ("v2" / "API 3" etc.).
- **Regional mode (issue #34)** is a hint-mode variant, not a
  parallel mode object. `UIElementSource.enumerateRegions()`
  walks the same AX tree with a different `WalkPolicy`
  (`regionalRoles` allow-list, default 200×100 frame floor —
  user-tuneable via `[regional].min-width` / `min-height`,
  `requirePress = false`) and `Controller.runHintFlow(…)`
  feeds the result through the existing label / overlay /
  dispatch pipeline. Action-mode modifiers apply unchanged —
  Cmd → copyTitle is the headline use case ("copy this article
  title to clipboard"). Entry is CLI-only via `perch overlay --regional`;
  there's no Carbon hotkey for it (users wire Karabiner / skhd
  / Raycast). **The shared `runHintFlow` is the right seam for
  any future "different enumerator, same pipeline" mode** —
  don't fork the overlay path for each new flavor.
- **Menu mode (issue #52)** is a `SearchMode` variant — same
  filter + KeyTap, different enumerator (`enumerateMenu()`
  walks `kAXMenuBarAttribute` recursively) and a different
  `SearchRenderMode` (`.verticalList` instead of pills over
  frames, because menu items have no on-screen frame until
  opened). `Controller.startSearchSession(…)` is the shared
  seam between `overlay --search` and `overlay --menu`; future search-flavour
  modes (window switcher, emoji picker) should slot in there
  rather than forking SearchMode. Menu items dispatch via the
  same `AXUIElementPerformAction(kAXPressAction)` as everything
  else — no special menu IPC.
- **Emoji picker (issue #55)** is a `SearchMode` variant that
  doesn't touch AX at all — `enumerateEmoji()` projects the
  curated `EmojiTable.entries` (≈400 rows, pure Core data) into
  `UIElement`s with ids of the form `"emoji:<glyph>"` and no
  `liveById` entry. `AXUIElementSource.act(id:.press)` checks
  the `"emoji:"` prefix and dispatches through
  `typeUnicodeString(...)` — `CGEvent.keyboardSetUnicodeString`
  with a 20-UTF16-unit cap, which fits every emoji in the
  table (the longest ZWJ sequences are ~11). **Don't reach for
  the synthetic Cmd+V path** — keeping perch pasteboard-clean
  is one of the issue's acceptance criteria, and the unicode
  payload route gets there without timing-dependent
  save/restore juggling. `.copyTitle` is the lone exception
  (writes the glyph to the pasteboard — the user asked for it
  explicitly). Table is intentionally curated, not the full
  CLDR ≈3700 — add entries when a user reports `"I typed X and
  got nothing"`, don't bulk-import.
- **Vision-OCR hints (issue #73 / M5)** are the **final
  AX-bypass layer**. Grid picks coordinates by labelled cells;
  vision picks by **what the text says** — Apple Vision's
  `VNRecognizeTextRequest` runs OCR on the main display capture
  and emits one `UIElement` per recognised string. Dispatch is
  synthetic `CGEvent` mouse click at the recognised centroid
  (no AX target — same as grid). Each result's id encodes the
  click point directly (`"vision:<x>:<y>"`) so dispatch needs
  no side-table.
  **Coord pipeline**: Vision's `boundingBox` is normalised
  bottom-left origin (0..1). The 3-step convert lands a click in
  the right place — multiply by image pixel size → flip Y to
  top-left → divide by `screen.backingScaleFactor` (HiDPI). Skip
  any step and pills go to the wrong place; the doc on
  `enumerateVision()` spells out why.
  **Screen Recording TCC grant** is required. `CGDisplayCreateImage`
  returns nil without it; we log + return empty so the overlay
  dismisses silently rather than crashing. Latency is 100-400ms
  per invocation — acceptable for the deliberate `overlay --vision`
  fallback, not the default path. **Don't try to integrate
  vision results with the hint walker** — different latency
  profile, different dispatch path, mixing them confuses the
  pipeline.
- **Grid mode (issue #66 / M4-α)** is the **explicit AX-bypass
  fallback** for UIs that hint mode can't see (Figma canvas,
  Photoshop, web `<canvas>`, custom-drawn views). Owns its own
  KeyTap + NSPanel (mirrors `SearchMode` / `ScrollMode`), divides
  the screen union into cells, and feeds synthetic `UIElement`s
  (id `"grid:<r>:<c>"`, role `"GridCell"`) through the existing
  `Labeler.assign(...)` so the alphabet matches hint mode.
  **Dispatch is `CGEvent` mouse events**, NOT
  `AXUIElementSource.act(...)` — there's no AX target for a
  cell. The cursor WILL visibly jump; that's the accepted
  trade-off (see "Mouse synthesis carve-out" above). Action
  mapping: bare → left click, Shift → right, Cmd → warp only
  (for the `overlay --drag` workflow), Cmd+Shift → left click + re-enter
  for chained operations. **Don't promote grid cells to
  AX-anchored UIElements** — the whole point is that no AX
  layer exists; the synthetic id is a marker, not a side-table
  key.
- **`overlay --grid` vs `overlay --rgrid` density** (PR #87 / #88): `overlay --grid`
  (single-pass) uses `[grid].cols × [grid].rows` (default 12×8);
  `overlay --rgrid` (recursive) uses `[grid].recursive-cols × .recursive-rows`
  (default **3×3**) **at every drill level**. Smaller per-step
  density keeps each pick a single-letter label. `[grid].max-depth`
  clamps to **1..10** (raised from 5 in PR #88 so 3×3 has
  headroom for pixel precision — 3⁷≈2pt cells on 4K, 3¹⁰≈59k
  cells per axis). Grid mode shares `OverlayCanvas` via
  `PillPlacement.elementCenter` (PR #87) so it picks up every
  visual surface (theme / shape / effects / border / sound /
  modifier-badge) hint mode has.
- **Hold-to-peek in grid** (PR #87): `[overlay].peek-key`
  (default `"space"`) also works in `overlay --grid` / `overlay --rgrid`.
  Space's old "click center at current depth" role moved to
  `Return` / `KeypadEnter` exclusively so peek doesn't shadow
  the terminal-click shortcut.
- **Window switcher (issue #54)** is another `SearchMode`
  variant — same shared `startSearchSession` seam, with
  `enumerateWindows()` walking `NSWorkspace.runningApplications`
  → each pid's `AXUIElementCreateApplication` → `kAXWindowsAttribute`.
  Two adapter-only quirks vs hint / menu mode:
  - **Dispatch diverges on role.** `AXUIElementSource.act(id:as:)`
    checks `kAXRoleAttribute == "AXWindow"` and routes `.press` /
    `.pressContinuous` through `kAXRaiseAction` + the owning
    `NSRunningApplication.activate(...)` (gated `if #available(macOS 14.0, *)`
    so we drop `.activateIgnoringOtherApps` on Sonoma+ where the
    option is deprecated). `kAXPressAction` on a window typically
    does nothing — don't reintroduce the press path.
  - **`.copyTitle` uses a label cache.** `customLabelById`
    stores the composed `"<App> — <Window Title>"` from
    `enumerateWindows()`; `act(id:.copyTitle)` reads it before
    falling back to live `kAXTitleAttribute`. Cleared at the top
    of every enumerator (`prepareWalkRoot`, `enumerateMenu`,
    `enumerateWindows`) so a stale composed string from a prior
    window-mode session can't leak into a later non-window
    copyTitle.
  Apps are filtered to `.activationPolicy == .regular` so
  faceless background tools (without user-switchable windows)
  don't pad the list, and `[behavior].exclude-apps` covers
  per-app blocking with the same knob hint mode uses.

### Logging

- **`Log` lives in `PerchCore`** so both the Adapter and App
  modules can call it without crossing layer rules. Two
  functions: `Log.line` (always on) and `Log.debug` (gated by
  `debugMode`, set from the `PERCH_DEBUG` env var at startup —
  the launcher sets it; a brew/raw launch stays quiet).
- **Both write to `/tmp/perch.log`**; `PERCH_DEBUG` also mirrors to
  stderr so foreground users see events live.
- **Use `Log.debug` liberally** in AX walk hot paths. It costs
  one bool check when disabled. Skip per-recursion logging on
  AX walks of deep windows — the cost adds up even with the
  gate.

### Debugging — how Claude Code observes a running daemon

perch is **headless** (`LSUIElement`, no Dock icon, no menubar
item). The agent cannot "look at the screen" to see what it's
doing — so the daemon is built to be debuggable entirely from
the terminal.

**Quick reference**: [docs/debugging.md](docs/debugging.md) has
the full workflow + log-format reference;
[docs/troubleshooting.md](docs/troubleshooting.md) has the
catalogue of "this bug signature → that fix" entries the M1 fix
wave produced.

The five-second triage:

1. **`./run.sh`** — stop any prior daemon, rebuild as a debug
   bundle, install + launch `Perch-dev.app`
   (`com.perch.perch.dev` bundle id so its TCC grant doesn't
   collide with a brew-installed Perch.app), tail the log.
   `PERCH_DEBUG=1` is set on the launched app so debug traces
   show up. Single dev-loop entry point — only repo contributors
   run this; end users `brew install`. Default is dev because
   that's the actual everyday call site. `./run.sh --no-tail`
   skips the tail; `./run.sh --release` builds the production
   bundle for pre-publish verification.
2. **`perch config --doctor`** — macOS / accessibility / config /
   daemon / screens / frontmost / log file. Every line is
   bug-report-grade information; copying the whole output is
   the single most useful triage attachment.
3. **`perch ax --dump`** — print every AX element perch would
   label in the current frontmost app. If the missing element
   is in the dump, the bug is in label assignment / overlay
   rendering; if it isn't, the bug is in the AX walk / filter
   chain.
4. **`perch ax --tree`** — print the **raw** AX tree
   (depth-first, pre-filter) of the focused window. Reach for
   this when `ax --dump` shows nothing where you expected a
   hint — most often a web shell (Chrome / Electron /
   WKWebView) where the element isn't even reaching the filter
   chain because the AX backend hasn't surfaced it yet. Look
   for `*WEB*` markers and inspect what's below them; the
   walker lifts its depth ceiling once it crosses one, so
   leaves 40+ levels below the web area now reach the dump.
5. **`perch ax --regions`** — same shape as `ax --dump` but
   for `perch overlay --regional` (issue #34). Lists the large
   containers regional mode would label, with the current
   `[regional].min-width / min-height` floor applied. Useful
   to tune the floor for a specific app ("Books labels nothing"
   → lower the floor; "GitHub labels every list item" → raise
   it).

A successful hint press leaves this trace in `/tmp/perch.log`:

```
hotkey: bound shift+space
ax: bounds cg=(…) ax=(…) → filter=(…)
ax: enumerated N hint(s) in <bundle-id>
activate: N hint(s)
dispatch: AXPress ok → id=<pid>:<seq>
```

Each missing line localises the failure to one stage (hotkey →
filter / AX enumeration → labeling → dispatch).

**AX grant after rebuild:** `swift build` ad-hoc re-signs the
binary, which can drop the Accessibility grant — the symptom is
`AXIsProcessTrusted() = false` in `perch config --doctor`, or
`kAXErrorAPIDisabled` (-25211) on every AX call in
`/tmp/perch.log` while the user reports "hints stopped appearing".
Persistent fix: run `./setup-signing-cert.sh` once;
`./package.sh` (called by `./run.sh` and `./run.sh --dev`) signs
Perch.app / Perch-dev.app with that identity, so TCC keys the
grant to the stable cert and survives subsequent rebuilds. Use
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

- **Grammar**: `perch <domain> --<verb> [VALUE]` (yabai-style
  domain-verb). Four domains: `config` / `ax` (standalone),
  `overlay` / `daemon` (need a running daemon, exit `3` if none).
  `config --validate` / `config --doctor` / `config --emit-schema`;
  `ax --dump` / `ax --tree` / `ax --regions`;
  `overlay --activate` / `overlay --scroll` / `overlay --search` /
  `overlay --regional` / `overlay --menu` / `overlay --windows` /
  `overlay --emoji` / `overlay --grid` / `overlay --rgrid` /
  `overlay --nudge` / `overlay --drag` / `overlay --vision` /
  `overlay --cancel` / `overlay --theme NAME`;
  `daemon --reload` / `daemon --quit` / `daemon --show`. Bare
  `perch` runs as agent / server; `--help` / `-h` is standalone.
  There is no `--debug` flag — verbose logging is driven by the
  `PERCH_DEBUG` env var (see Logging). Each domain takes exactly
  ONE verb — combining verbs (`daemon --reload --quit`) or using a
  flag outside its domain exits `2` with a stderr message (no
  silent fallback — facet's *Rule of Repair* discipline; an
  unknown flag prints a "did you mean …?" hint). **`overlay
  --theme NAME` takes a space-separated value** (`overlay --theme
  ''` clears the override; bare `--theme` with no value is an
  error). Powered by the shared sill `CLIKit` tokenizer; perch
  keeps its own verb vocabulary.
- **`config --doctor`** reports Accessibility (`AXTrust.isTrusted()`),
  config, daemon liveness, configured hotkey, and alphabet length.
  Exit 1 if AX fails.
- **`overlay --activate` / `overlay --scroll` / `overlay --search` /
  `overlay --cancel` are the
  CLI mirror of the global hotkey**, posted over the same DNC
  channel as `daemon --reload`. They let Karabiner / skhd / Raycast
  script commands trigger any of the three modes without giving
  up perch's built-in Carbon hotkey, and make shell-script
  triggers cheap. Each is symmetric with its entry point: a
  second invocation while the mode is up cancels (same path as
  `overlay --cancel`). All three modes are **mutually exclusive** —
  entering one while any other is up tears the first one down
  first so the single session-level KeyTap installs cleanly.
  Don't tee these through a second IPC mechanism —
  `installControlObserver` is the single observer.
- **`daemon --reload` / `daemon --quit` talk to the running daemon over
  Distributed Notification Center** (`com.perch.app.control`,
  see
  [Sources/PerchApp/Control.swift](Sources/PerchApp/Control.swift)
  + `Controller.installControlObserver`) — same pattern as
  stroke / facet. Don't invent a different IPC. They exit `3`
  if no daemon is running.
- **`daemon --show` is one-way the other direction**: DNC can't reply,
  so the daemon rewrites a small status file (`statusPath` =
  `/tmp/perch.status`) on start / reload / each hint press, and
  `daemon --show` just reads it.
- **CLI surface conventions when adding new flags** — same shape
  as the Configuration rules (memory `user-collaboration-style`):
  - **Prefer the dominant style.** The surface is `perch <domain>
    --<verb> [VALUE]`; verbs are overwhelmingly bare `--<name>`,
    with `overlay --theme NAME` the lone value-taking verb (a
    space-separated string, never `--theme=NAME`) — it pays for
    itself by giving the user a one-shot override. Don't introduce a
    *second* value-taking verb, a `--<verb>-<noun>` style, or a
    positional argument without a real need. Mode entries are always
    `overlay --<mode-name>` (no `--enter-<mode>` / `--start-<mode>`
    ceremony).
  - **Match the existing family naming.** AX diagnostics live under
    the `ax` domain (`ax --dump` / `ax --tree` / `ax --regions`).
    Mode entries are bare nouns under `overlay` (`overlay --grid` /
    `overlay --vision`). Daemon-control verbs are bare imperatives
    under `daemon` (`daemon --reload` / `daemon --quit`) — `overlay
    --cancel` mirrors the mode-cancel path. Pick the matching domain
    + family before inventing a new verb.
  - **Breaking renames are OK when they buy consistency.** Same
    stance as the config-knob rule (the user's repeated
    "破壊的変更OK / 一貫性の方が重要だから"). Unrecognised flags
    exit `2` — there's no typo-tolerance fallback to silently mask
    a renamed flag — so the rename is loud by default. Land the
    rename + a short README delta in the same PR, and (if the old
    name was advertised) keep an alias for one release before
    dropping it.
  - **No nested-flag forms** (`--overlay.theme=<name>`,
    `--effect:appear=<kind>`). The TOML file is the right surface
    for nested knobs; the CLI is for *modes* + *one-shot session
    overrides* (`overlay --theme NAME`). If the urge to nest comes up,
    add a TOML knob and reload, don't invent CLI namespacing.

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
  *(reviewed 2026-05-24)* — perch's config is parsed by
  swift-toml-edit's `Toml.parseFlat` (Sill-1, full TOML 1.0). perch's
  `config.toml` uses a flat dotted-section subset, but new `.toml`
  surface is bounded by the shared lib, not a local parser budget.
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
- [Surfingkeys (brookhong)](https://github.com/brookhong/Surfingkeys)
  *(reviewed 2026-06-04)* — vim-style hint mode in the browser,
  DOM-based (not AX). UI conventions transfer; the seam doesn't.
  Useful as reference for: regional hints (roadmap M3, "Regional
  Hints" / `L`), continuous-follow mode (label → click → label
  again, no re-hotkey, for list processing), overlapped-hint
  disambiguation via modifier (Shift to flip stacked candidates).
  vimac / Homerow are the closer references for the AX-based
  Mac path — Surfingkeys' value here is on the keyboarding UX,
  not the element-enumeration mechanism.

## Shared libraries (atelier)

このアプリは swift app family の共有ライブラリに乗る（plan [atelier](https://github.com/akira-toriyama/atelier)）。
共有 lib が持つ責務は**再実装せずライブラリ側を拡張**する（北極星＝「facet の theme を真似て」を二度と言わない）。
モジュール → target の正確な配線は [Package.swift](Package.swift) を正とする。

- **[sill](https://github.com/akira-toriyama/sill)** — 共有 theming / CLI 基盤。設計 → [`docs/DESIGN.md`](https://github.com/akira-toriyama/sill/blob/main/docs/DESIGN.md)。perch が使う: `Palette`（theme catalog）/ `CLIKit`（CLI tokenizer）/ `ConfigSchema`（taplo schema）。
- **[swift-toml-edit](https://github.com/akira-toriyama/swift-toml-edit)** — family 唯一の TOML 実装（`Toml` module・Swift 版 toml_edit）。perch は config.toml パースに使用。

**自己完結しない — 共有候補は sill に PR を模索**: app 単独で実装する前に「2 つ以上の app で冗長になりそうか」を問い、そうなら sill への PR を検討する（過剰共通化はしない・zero-debt ≠ 全部共有）。

## Roadmap board (GitHub Projects)

issue 運用（集約 Project「roadmap」#5・Inbox 既定 / Status フロー / `Closes #N`）は
family 共通ポリシー。正典 → https://github.com/akira-toriyama/atelier/blob/main/docs/roadmap-board.md
