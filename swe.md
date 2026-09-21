# swe.md — Invoque review

A full pass over the codebase (~23.5k lines of Swift, all source files read).
Overall verdict first, then findings grouped by theme, then a prioritized
implementation plan.

## Verdict

This is a genuinely well-built app, not a prototype. The hard parts of a
launcher are handled correctly: Carbon hotkey registration with rollback,
keyboard-layout-aware hotkey display, activation handoff that restores focus
to the previous app, asynchronous app/command scanning with stale-result
drops, symlink-safe command loading, permission grants bound to SHA-256 of
the entry file, a capability-gated JS bridge, redirect-revalidating fetch,
reduce-transparency/motion support, adaptive icon accents, and a real test
suite (40+ test files covering the pure logic).

The weaknesses are mostly at the edges: a few real bugs, several promised
features that never landed (PLAN §6 `edit`, §7 Commands/Permissions tabs,
⇧⏎ secondary action), some wasted-work paths when the panel hides, and a
long tail of launcher-convention features (⌘K actions, Quick Look, forced
web search, command arguments) that separate a good launcher from a great
daily driver.

---

## 1. Confirmed bugs

### B1. README download link points at the wrong repo
`README.md:3` links `https://github.com/L-K-M/Vervellum/releases/latest` —
"Invoque" was templated correctly everywhere else but the download target is
a different project name. Anyone clicking Download gets another repo's
releases (or a 404).
Fix: s/Vervellum/Invoque/. Trivial.

### B2. Missing JIT entitlement — all JavaScript runs interpreted
`Invoque/Invoque.entitlements` is an empty `<dict/>`, yet
`ENABLE_HARDENED_RUNTIME = YES` (project.pbxproj) and JavaScriptCore is the
command runtime. Under Hardened Runtime without
`com.apple.security.cs.allow-jit`, JSCore cannot map executable JIT pages and
falls back to the interpreter — an order of magnitude slower on hot JS. This
hits exactly the hot path: filter-mode commands run per keystroke.
`AGENTS.md:38` even documents that the entitlement "gets added together with
the JavaScriptCore runtime" — it never was.
Fix: add `com.apple.security.cs.allow-jit = true` to the entitlements file.
One line, high leverage.

### B3. Hiding the panel does not cancel in-flight work
`PanelController.hide()` (Panel/PanelController.swift:142) only `orderOut`s.
Nothing reaches the model's `cancelFileSearch`/`cancelFilterRun`, and
`MakerModel.discard` is not called. Consequences:
- Esc mid-`find` leaves a whole-disk walk running to completion — potentially
  minutes of wasted I/O on every dismiss.
- An in-flight filter run lands its rows into a hidden list (harmless but
  wasted JS work).
- A `make` generation keeps burning API tokens for up to the 300 s
  `generationBudget` after the user dismissed the panel — real money.
Fix: give `PanelModel` a `panelDidHide()` that cancels the file session and
filter task, and cancels the maker's generation task (without wiping the
transcript, so re-summoning can still retry).

### B4. Selection scrolling re-centers on every arrow press
`PanelView.swift:312-315` and `DetachedSearchView.swift:148-151` call
`proxy.scrollTo(id, anchor: .center)` whenever the selection id changes. With
a list longer than the viewport, every ↑/↓ visibly drags the list so the
selected row is centered — even when it was already fully visible. Spotlight,
Raycast and Alfred all scroll minimally (only when the target row is off the
edge). The re-centering also fights the 0.1 s selection animation.
Fix: `proxy.scrollTo(id)` with no anchor (or `.bottom`/`.top` based on
direction) — scrolls the minimum needed.

### B5. System actions can fail silently
`SystemActionPerformer.swift`: restart/shutDown run `osascript` — a denied
Automation consent exits non-zero and only `NSLog`s (line 44-48). Empty Trash
deletes `~/.Trash` entries one-by-one on the **calling (main) thread**
(line 60-74): a Trash with thousands of entries stalls the UI, per-item
failures are logged but invisible, other volumes' `.Trashes` are ignored, and
there is no confirmation for an irreversible action one Return press away.
Fix: run the removal on a background queue; HUD the outcome ("Trash emptied"
/ "Couldn't empty N items"); consider a confirm step or Finder fallback for
the destructive path.

### B6. `invoque.fetch` buffers responses with no size cap
`InvoqueBridge.swift:266` uses a plain `dataTask` — the entire body is
accumulated in memory, then converted to a JS string. A command fetching a
multi-GB URL (or a URL that lies about Content-Length) can exhaust memory.
Fix: stream with a byte cap (~20 MB) and reject with a clear error past it.

### B7. App catalog is frozen at launch
`AppSource` scans once at startup (async) and nothing ever re-triggers it —
no `NSWorkspace.didLaunchApplicationNotification` /
`didTerminateApplicationNotification` observation, no FSEvents on
`/Applications`, no periodic rescan. An app installed (or moved to Trash)
mid-session is wrong until relaunch. Contrast: `CommandStore` already watches
its directories properly with `DispatchSourceFileSystemObject`.
Fix: observe `NSWorkspace` launch/terminate notifications (debounced) and
re-scan; cheap and self-contained.

### B8. `.enterFilter` picks never train frecency
`PanelModel.submit` intercepts `.enterFilter` before `onSubmit` fires, so
`PanelController`'s `recordSelection` never runs for filter commands — the
most-used filter keyword never rises in the ranked list.
Fix: record the selection in the `enterFilter` branch too.

### B9. Selection double-publish on streamed updates
`DetachedSearchModel.refresh` sets `rows` (didSet → `selection = 0`) then
re-assigns `selection` to the tracked index — two objectWillChange cycles and
a transient "selection at top" state per batch. `PanelModel.
fileSessionDidUpdate` has the same pattern. Cosmetic, but it feeds the `.task`
scroll hook a phantom id change.
Fix: assign rows and selection atomically (compute index first, or drop the
didSet reset in favor of explicit resets).

### B10. Action-mode commands can never receive arguments
`CommandSource.swift:46` hard-codes `.runCommand(manifest.name, [])` — the
only input an action command gets is nothing. There is no `keyword args`
surface for action commands (Alfred's core interaction model), so e.g. a
"resize image" command must be a filter or take no input at all.
This is partly a design decision — `keyword <args>` claiming a normal query
is a policy choice — but as shipped, the `args` parameter of the public
`invoque` contract is unreachable from the UI.
Fix option: when the first token is an action command's name or first
keyword, run it with the remainder as args (same routing rule filter mode
already uses). Needs a manifest/policy decision; listed as a feature below.

### B11. Esc during a `make` generation doesn't cancel anything
Related to B3 but worth its own line: `MakerView` shows a spinner with no
Cancel affordance, and `Esc` → hide leaves `generationTask` running. The
result lands in `MakerModel`'s state for a session the user walked away
from — and if they re-summon and retype `make …`, they see a stale phase.
Fix: a Cancel button on `generatingContent` + cancel-on-hide (B3 covers the
wiring).

---

## 2. Correctness risks / general issues (not confirmed defects)

- **C1. JSRuntime can't kill tight synchronous loops** — documented and
  handled with a "stuck for session" flag, but a stuck command is invisible
  to the user. Surface it (HUD or a small status affordance) so users know
  why a command stopped answering.
- **C2. Shell bridge runs the subprocess synchronously on the JS queue** —
  timeout coverage exists via the invocation budget, but a `shell` call that
  outlives the timeout may leave the child process running. Verify kill
  semantics; document or enforce.
- **C3. `Frecency.score` takes `NSLock` + calls `Date()` per item per
  keystroke.** ~600 items × per keystroke is fine today, but it's a
  needless hot-path cost — a `snapshotScores()` bulk read would drop the
  lock-per-item.
- **C4. `topHits()` iterates every source's full item list on every empty
  query** (each summon, each cleared field). Bounded (~600), but it's all
  allocation on the main thread. A cached "eligible items" list would help.
- **C5. Permission grants are irrevocable from the UI.** A granted `shell`
  or `paste` consent lives in `UserDefaults` forever; no Settings surface
  lists or revokes them. For a consent system this is a real gap — see F4.
- **C6. `NSWorkspace.icon(forFile:)` resolved per row per render** in
  `PanelView.iconImage` (line 180) and `DetachedSearchView` — up to 50
  synchronous workspace lookups per publish. The system caches, but an
  app-side `NSImage` cache keyed by path (already half-present via PictKit
  for app icons; file icons bypass it) removes the risk entirely.
- **C7. `UpdateChecker` runs against `L-K-M/Invoque`** — consistent with
  the repo, but it makes B1's README link stand out even more.
- **C8. No localization** — every string is hard-coded English. Fine for v1;
  worth noting since the theming system is so polished.
- **C9. `panel.orderFrontRegardless()` + makeKey** on `show()` is right, but
  `show()` doesn't re-check that the app is still appropriate to present —
  e.g. during a modal alert the panel could overlap it. Low risk.
- **C10. Test coverage gaps** — `InvoqueBridge` (the security-critical
  surface), `PanelController`, `LauncherPanel`, and the detached window are
  thinly covered; GUI limits are real but bridge-level unit tests for fetch
  redirect rules, file scoping and shell drains are feasible.
- **C11. `stabilizedRankedRows` allocates a Dictionary + Set + re-matches
  every row per keystroke** — bounded at 50, fine, but the double
  `FuzzyMatcher.match` per row per keystroke is the kind of thing that adds
  up on slower Macs. Acceptable.

---

## 3. Performance & stuttering

| # | Where | Issue | Fix |
|---|-------|-------|-----|
| P1 | `Invoque.entitlements` | JS interpreter-only (B2) — biggest perf win in the app | add allow-jit |
| P2 | `PanelView` row build | `NSWorkspace.icon` per row per keystroke (C6) | icon cache keyed by path |
| P3 | `CRTScreenOverlay` | Canvas re-draws ~150 scanline fills + radial gradient on every publish (every keystroke) when enabled | render once into an image/layer, or `.drawingGroup()` |
| P4 | `SystemActionPerformer.emptyTrash` | bulk file deletion on main thread | background queue + completion HUD |
| P5 | `FileSearch` | `standardizedFileURL.path` + `fileExists` per directory — OK; bounded | none needed |
| P6 | `Frecency` | lock + Date per item per keystroke | bulk score snapshot |
| P7 | `PanelModel` | scroll re-center + double publish (B4/B9) — visible jitter | minimal scroll, atomic selection |
| P8 | `AppCatalog` initial scan | async, good; but `Bundle(url:)` per app — fine | none |
| P9 | `FileSearchSession` | full accumulated snapshot per batch — O(matches) copies; fine | none needed |
| P10 | `Maker` LLM request | non-streaming, up to 300 s of silence with a spinner | streaming or at least elapsed-time display + Cancel |

The single most impactful item is P1 — it multiplies the speed of every
command and every filter keystroke for free.

---

## 4. Missing features (vs Alfred / Raycast / Quicksilver)

Ranked by expected daily-driver value:

1. **F1. ⌘K-style action panel / secondary actions.** PLAN §3 promised
   "⏎ = default, ⇧⏎ = secondary" — no secondary action exists. Per-row
   actions are the biggest launcher convention still missing: Copy Path,
   Reveal, Open With…, Get Info, Quick Look, Uninstall (apps), Copy Title.
   Even without a ⌘K sheet, ⌘C-to-copy-path + richer context menu is most
   of the value.
2. **F2. Forced web search keyword.** `search ` was taken by file search;
   there is **no way to web-search a query that also matches an app**.
   `web <q>` (or `g `) should route straight to the web row.
3. **F3. Commands tab in Settings** (PLAN §7.3): list loaded commands
   (title, mode, permissions, origin), "Open Commands Folder", per-command
   enable/disable, and permission-grant revocation (C5). Users currently
   cannot even discover `~/.config/invoque/commands` from the UI.
4. **F4. Permission-grant management** — revoke `shell`/`paste` consents.
   (Fold into F3.)
5. **F5. Quick Look** on file/app rows (Space or ⌘Y) — QLPreviewPanel
   works with a borderless panel; delightful and cheap-ish.
6. **F6. Action-command arguments** (B10) — `keyword args` routing.
7. **F7. `edit <name>` Maker flow** — PLAN §6 explicitly deferred; the
   writer's `history/` snapshotting already supports it.
8. **F8. Revert to revision N** — history exists as files; surface it.
9. **F9. Clipboard history** (opt-in; PLAN lists as candidate). Needs a
   poll timer + storage + privacy care.
10. **F10. Snippets / canned text** — paste-on-pick.
11. **F11. Calculator+: units & currency** (with cached rates), percent
    handling (`20% of 80`), hex/bin conversion.
12. **F12. Recent documents source** (`NSDocumentController` recents don't
    cover all apps; alternatively `~/Library/Application Support/*/Recents`
    or Spotlight's kMDItemLastUsedDate — last is off-limits by design, so
    maybe skip).
13. **F13. Query history** — ↑ on an empty field recalls previous queries
    (shell muscle memory).
14. **F14. Per-command global hotkeys** — bind a chord to a command.
15. **F15. `invoque://` URL scheme** — `invoque://search?q=…`, for external
    automation and other apps to drive it.
16. **F16. Window management actions** (left half, maximize…) — AppleScript/
    AX-based; consent cost is real.
17. **F17. Kill-process action** on running apps ("Quit Safari").
18. **F18. Emoji / symbol source** — `emoji fire` → 🔥; pure data file.
19. **F19. File-search detach upgrade** — detached window is read-only;
    a filter field inside it would make it a real browser.
20. **F20. "Remind me" / timer built-ins** — small system actions.
21. **F21. Accessibility permission surface** (PLAN §7.5): status + a
    button that triggers the prompt, instead of only discovering it via a
    paste command.
22. **F22. Panel position/size preferences** — vertical offset, width,
    screen choice (under-cursor vs main).

## 5. UX & keyboard flow

- **U1.** B4 scroll jump is the most felt issue.
- **U2.** No hover-to-select — moving the mouse over rows doesn't move the
  selection (Spotlight does). One `onHover` + select; subjective.
- **U3.** No visible result count or "mode" badge in the panel footer —
  the detached window has a match count; the panel could say "9 results"
  or show the active filter keyword chip.
- **U4.** `Tab` does nothing — could complete the top row's title or enter
  filter mode (Raycast uses it for arguments).
- **U5.** Pinned/blocked Settings lists show raw ids (`app:com.foo.bar`) —
  strip the prefix for readability.
- **U6.** Maker: no elapsed-time/progress feedback during a 5-min-budget
  generation; no Cancel (B11).
- **U7.** `moveSelection` wraps at the ends — Alfred/Raycast don't wrap;
  wrap is defensible (Spotlight does) but consider making it a no-wrap or a
  preference.
- **U8.** On a failed filter command, the error row's action is
  `copyText(message)` — good. But there's no "open the command's folder"
  or "view log" affordance for debugging.
- **U9.** Detached search window: no PgUp/PgDn/Home/End/⌘↑⌘↓.
- **U10.** No "copy answer" hint on the calculator row — ⏎ copies, but a
  subtitle saying so teaches it.
- **U11.** First-run experience: nothing tells a new user the hotkey is
  ⌥Space — the menu item could carry the chord's glyphs.

## 6. Visual & layout

- **V1.** The panel is 680×440 fixed — fine, but a compact mode (fewer rows,
  smaller) and a wide mode would help; at minimum a width preference.
- **V2.** The 25%-down placement is hardcoded (`PanelGeometry`) — a vertical
  offset slider or drag-to-position would be a nice Appearance addition.
- **V3.** `Icon 28pt` + two-line rows is roomy; an optional compact row
  density (Alfred-style) would fit more results.
- **V4.** The footer hint line is dense — separate "chords" into a right
  cluster and the mode hint left, so it scans faster.
- **V5.** `DetachedSearchView` is a plain window — it ignores the theme
  entirely. Intentional (it's a browser, not the card), but applying the
  typeface/highlight at least would unify it.
- **V6.** The boing ball and CRT are corner-scoped; a "chrome" decoration
  option (full border stripe) exists in spirit already via PanelDecoration.
- **V7.** Appearance preview is excellent (real `PanelView`). Could add a
  "screenshot this theme" export button for sharing presets with a preview.

## 7. Theming opportunities

- **T1.** Per-appearance dark/light variants — a theme that picks tint pairs
  and follows `colorScheme`.
- **T2.** Scheduled themes (Synthwave by night, Memphis by day).
- **T3.** Accent follows wallpaper — sample `NSWorkspace.desktopImageURL`.
- **T4.** Sound pack hooks — optional key ticks / launch whoosh per theme
  (off by default; delight knob).
- **T5.** Theme gallery inside Settings — thumbnails of built-ins instead of
  a text menu.
- **T6.** Animate the boing ball on summon (a single bounce) when the Amiga
  theme is active — tiny `withAnimation` on first appear.
- **T7.** CRT power-on: brief flicker+expand animation when the panel
  summons under a CRT-enabled theme — very on-brand.
- **T8.** Import/export whole settings bundle (not just appearance).

## 8. Delightful / novel ideas

- **D1. CRT power-on summon animation** (T7) — the panel "warms up" like a
  phosphor tube for ~150 ms. Pure joy, cheap.
- **D2. EGG: typing `invoque` shows a credits/easter-egg card** with the
  boing ball bouncing and version info.
- **D3. "Time saved" stat** — count launches and quietly show "Invoque has
  launched N apps for you" in Settings → General footer.
- **D4. Query ghosts** — a faint inline completion (like Fish autosuggest)
  offering the top hit's title in the field itself; Tab to accept (U4).
- **D5. Confetti burst on Maker save** — one-shot, only when `decorationStyle
  != .none`; earned delight.
- **D6. Shake-to-clear** — Esc on an already-empty query could clear the
  frecency rail highlight or do nothing; alternatively Esc-Esc clears query
  when keepQuery is on.
- **D7. Seasonal built-in theme** (a snow/Halloween decoration style) —
  PanelDecoration already supports pluggable styles.
- **D8. `fortune`/`tip` empty-state** — the empty-query rail could show a
  rotating tip line under the field when there are no frecency hits yet.
- **D9. A `roll`/`flip` calculator easter egg** — `flip a coin`, `roll d20`
  → animated result row.
- **D10. Panel "pet"** — the boing ball idles/bounces while the panel is
  open under the Amiga theme (animate on a slow timer; respect Reduce
  Motion).

## 9. Implementation plan (what I'm doing)

Each on its own branch → PR against `main`. Ordered by value/risk:

| PR | Branch | Scope | Size |
|----|--------|-------|------|
| 1 | `fix/readme-download-link` | B1 | xs |
| 2 | `feat/jit-entitlement` | B2 | xs |
| 3 | `fix/cancel-work-on-hide` | B3 + B11 (file walk, filter run, maker generation cancelled on dismiss) + tests | s |
| 4 | `fix/minimal-scroll` | B4 (+B9 atomics if clean) | xs |
| 5 | `feat/web-keyword` | F2 — `web <q>` forced web search | s |
| 6 | `feat/copy-actions` | F1-lite — ⌘C copy path/URL/title + context-menu Copy | s |
| 7 | `feat/app-rescan` | B7 — rescan on NSWorkspace app launch/terminate | s |
| 8 | `feat/detached-window-keys` | U9 | xs |
| 9 | `feat/empty-trash-safe` | B5-trash part — off-main + HUD result | s |
| 10 | `feat/fetch-size-cap` | B6 | s |
| 11 | `feat/maker-cancel` | B11 cancel button | xs |
| 12 | `feat/commands-tab` | F3+F4 — list, open folder, revoke grants | m |

Everything else stays here as the backlog and lands in `ANALYSIS.md` when
the PRs are done.
