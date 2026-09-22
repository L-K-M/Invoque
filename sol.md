# Invoque review

Audit baseline: `e8b96b8` on 2026-09-21.

This is a static review of the app, tests, project, workflows, plans, and icon
assets. The host is Linux, so I could not launch the macOS UI, profile it, run
`xcodebuild`, inspect VoiceOver, or test multiple displays/Spaces. Main's last
code revision had green macOS CI. Runtime appearance and latency findings below
that need a Mac are marked as verification work rather than claimed as measured.

## Verdict

The project has unusually broad unit coverage and several sound foundations:
nonactivating AppKit windowing, capability-based JavaScriptCore contexts,
stable ranked search, streamed file results, plain-file commands, safe direct
open-path handling, Keychain storage, and an appearance system with real
character.

It is not ready to displace Alfred or Raycast yet. The main gaps are safety at
side-effect boundaries, first-summon and per-keystroke work, command inspection
and management, incomplete app/file indexing, and basic launcher affordances.
Several documented features are only schema or UI stubs.

Priority meanings:

- **P0**: data loss, capability escape, or runaway resource use.
- **P1**: user-visible correctness, latency, accessibility, or major trust gap.
- **P2**: product completeness and polish.
- **P3**: optional or experimental.

## P0: fix before broader use

### 1. Destructive system actions execute too easily

**Evidence:** `PanelView.resultList` executes on one mouse click;
`SearchField` routes Return through `PanelModel.submit` to the same action;
`SystemSource` offers Restart, Shut Down, and Empty Trash; and
`SystemActionPerformer.perform` dispatches them without an Invoque confirmation.

**Impact:** A stray click or Return can shut down the Mac or permanently delete
Trash contents. The launcher disappears before the user can recover. Empty
Trash also deletes only `~/.Trash`, while its subtitle says "everything";
external-volume trash is left behind.

**Change:** Add a trusted in-panel confirmation state for restart, shutdown, and
empty trash. Require an explicit chord or button, never a second plain Return.
Show item count where available. Keep lock and sleep immediate. Prefer Finder's
semantics for all mounted-volume trash, or rename the action honestly.

**Proof:** Model tests for neutral Return, explicit confirmation, cancellation,
and no dispatch before approval; manual mouse and keyboard verification.

### 2. `shell.run` survives the runtime timeout

**Evidence:** `InvoqueBridge.swift:359-411` waits synchronously for `Process`;
`JSRuntime.swift:75-104` only completes the caller's continuation on timeout.
It cancels fetches but has no process registry. `PipeDrain` has no byte cap.

**Impact:** `yes`, a hung child, or a forked process can continue indefinitely
after Invoque reports a timeout. It can retain a worker thread, process,
JavaScript context, and unlimited stdout/stderr memory. Refusing later runs does
not reclaim the first one.

**Change:** Register child processes per invocation, launch a process group,
cap each output stream, terminate then kill the group on timeout/cancellation,
and report truncation. Make shell async so the JS queue is not parked in
`waitUntilExit`.

**Proof:** Regression tests with a non-terminating child, a backgrounded child,
and output over the cap; assert process exit, bounded memory/output, and a
returned timeout.

### 3. Always-on storage can escape through a `data` symlink

**Evidence:** `Command.dataDirectory` is a lexical child
(`Command.swift:22-25`). `installStorage` writes there without canonical
containment checks (`InvoqueBridge.swift:128-169`). The file module canonicalizes
`data`, but treats an already-external symlink as its allowed root
(`InvoqueBridge.swift:313-350`).

**Impact:** A copied command, or an existing generated command updated in a
directory containing `data -> /path/outside/command`, can use permission-free
storage to write outside its command directory. This contradicts the capability
boundary.

**Change:** Reject a command whose existing `data` path is a symlink or resolves
outside the canonical command root. Recheck at open/write time with no-follow
semantics where possible. Make `CommandWriter` reject or replace pre-existing
symlinked destination components.

**Proof:** Create `data` and nested destination symlinks to a sentinel directory;
loading/writing must fail and the sentinel must remain byte-identical.

### 4. Capability consent does not cover the practical exfiltration path

**Evidence:** only `shell` and `paste` are risky
(`CommandPermissionGrants.swift:26`). `clipboard.read` plus `network` or `open`
can transmit clipboard contents with no prompt. Search rows do not render any
permission badge. The gap is acknowledged in `PLAN.md`, but current UI leaves
the user no run-time signal.

**Impact:** A generated command can read and exfiltrate clipboard text after a
normal Return. A manifest declaration is not meaningful consent when the
launcher does not display it.

**Change:** Treat ambient reads plus egress as a risky permission combination.
Show capability badges on every command row and an inspectable permission sheet.
Bind consent to the exact source snapshot and full executable file set. Consider
HMAC-protected grants only as tamper evidence, not as a sandbox.

**Proof:** Permission matrix tests for `clipboard.read + network/open`, UI tests
for badges and consent, and source-change tests across every executable file.

### 5. Command outputs and logs are unbounded

**Evidence:** `JSRuntime.decode` bridges the complete returned array;
`PanelModel.commandRows` maps every item; `showCommandResults` applies no
`SearchModel.maxResults` cap. `CommandLog` appends every line forever.
Fetch, storage, fs, shell output, and generated response sizes also lack useful
limits.

**Impact:** A buggy or hostile command can freeze SwiftUI, allocate large
objects, or exhaust memory/disk. Filter mode repeats the cost per keystroke.

**Change:** Define public budgets for item count, title/subtitle/arg bytes, log
lines/bytes, fetch body, storage file, fs reads/writes, and LLM response. Truncate
with explicit diagnostics. Render capped command rows lazily.

**Proof:** Return oversized result arrays, strings, bridge payloads, and logs;
assert bounded memory/disk, explicit truncation diagnostics, and responsive UI.

## P1: correctness and reliability

### 6. An old command completion can dismiss a new interaction

**Evidence:** `PanelController.runCommand` checks query/session only for
`.items` (`PanelController.swift:188-199`). Errors, `.title`, and `.void` always
hide the panel at `PanelController.swift:181-205`.

**Impact:** Run a slow command, hide or edit the query, summon again, then let
the old command finish. It can hide the new panel and show a stale HUD. Merely
changing the query does not invalidate that completion. Repeated Return also
starts duplicate side effects with no busy state.

**Change:** Issue an invocation ticket containing run generation, panel session,
and submitted query. Gate every completion shape. Add a visible running state
and suppress duplicate submit unless the command explicitly supports parallel
runs.

**Proof:** Regression tests for hide/resummon, query change, a newer command,
and repeated Return.

### 7. Generated code is never shown before Save

**Evidence:** `MakerView.swift:188-229` shows title, permissions, file names, and
line count, not file contents or a diff. `MakerModel` permits Save as soon as
validation is clean, and Return saves in `readyToSave`. This conflicts with the
research claim that generated code is shown before save.

**Impact:** The product's core trust proposition is inspectable commands, but
the highest-risk moment hides the code. The generic shell consent does not show
the shell command either.

**Change:** Add a source inspector with manifest/source tabs, syntax-highlighted
or monospaced selectable text, permission call-site highlights, and a real diff
for revisions. Mark untested drafts. Put Save beside Inspect, not behind a bare
habitual Return.

**Proof:** UI tests for all generated files, source changes after feedback,
permission call sites, and no Save path that bypasses the inspector policy.

### 8. The system prompt makes two false promises

**Evidence:** `SystemPrompt.swift:70` calls `notify` user-visible, but
`InvoqueBridge.swift:99-104` only logs it. `SystemPrompt.swift:105` says a hung
command is killed, while `JSRuntime` abandons its context and thread.

**Impact:** Models generate behavior that cannot work and may assume runaway
work is terminated. Users see a "valid" draft that silently fails its promised
notification behavior.

**Change:** Implement notifications or describe logging honestly. State that
synchronous loops cannot be killed and permanently disable the command until
restart. Keep PLAN, bridge, validator, and prompt generated from one API
contract where practical.

**Proof:** Contract tests must compare prompt claims with installed bridge
methods and exercise notification and timeout behavior end to end.

### 9. Manifest arguments are dead schema

**Evidence:** arguments decode in `CommandManifest.swift:31-45,110`, but the only
action row is `.runCommand(manifest.name, [])` in
`CommandSource.swift:46`. No argument form reads `manifest.arguments`.

**Impact:** Commands that require arguments cannot be used from search. Maker can
generate a schema-valid command whose main feature is unreachable.

**Change:** Selecting an argumented action should morph the panel into a compact
argument editor with required/optional validation, history, Tab traversal, and
Esc back-navigation. Alternatively remove arguments from v1 and reject them.

**Proof:** Create required and optional argument manifests; verify keyboard
entry, validation, history, dispatch order, cancellation, and malformed types.

### 10. Permission checks and executed bytes have a TOCTOU gap

**Evidence:** consent hashes the entry during `consentRequest`, then `JSRuntime`
reads it later on its queue (`JSRuntime.swift:121-129`). A previously granted
file can change between the no-prompt check and execution.

**Impact:** Different bytes can execute under consent granted to an earlier
snapshot. Hot-reload makes this race plausible during editor atomic saves.

**Change:** Snapshot source and digest at dispatch. Consent and execution must
use that same immutable snapshot. Include executable helpers if module loading
is added.

**Proof:** Swap source bytes after consent and after dispatch; only the consented
snapshot may execute, and every changed executable must require new consent.

### 11. Reduce Transparency does not choose an explicit opaque surface

**Evidence:** `PanelBackground.glass` routes Reduce Transparency to
`fallbackGlass`; `fallbackGlass` still creates an `NSVisualEffectView` wrapper,
while effective opacity only changes solid/gradient fills. AppKit may adapt that
view itself, so the resulting alpha needs runtime verification.

**Impact:** The code does not explicitly guarantee that the configured glass
surface becomes opaque. Appearance may also differ across macOS releases.

**Change:** Under Reduce Transparency, render an explicit opaque semantic or
theme fill. Add Increase Contrast handling and a visible focus/selection outline.

**Status:** Explicitness gap; whether the current surface is already opaque is
unverified, so treat this as investigation work until runtime proof lands.

**Proof:** Inspect the composited alpha and screenshots with Reduce Transparency
on and off on macOS 13, 15, and 26; verify no blur/backdrop view in reduced mode.

### 12. First summon performs synchronous command I/O

**Evidence:** `panelController` is lazy. Its first access calls
`CommandStore.startWatching()` on the main thread (`AppDelegate.swift:139`),
which recursively scans and opens watchers. It then schedules a second complete
scan at `AppDelegate.swift:211`.

**Impact:** The first hotkey press can stall before any panel appears, especially
with many commands or nested files. This breaks the core latency promise.

**Change:** Construct and warm the panel after launch, scan commands off-main,
publish an immutable initial snapshot, and remove the duplicate scan. The panel
must appear immediately with available sources and fill incrementally.

**Proof:** signpost hotkey-to-first-frame and test cold/warm p50/p95 with 0, 100,
and 1,000 synthetic commands.

### 13. Search does excessive work per keystroke

**Evidence:** `FuzzyMatcher` lowercases and creates four `[Character]` arrays per
candidate. `SearchModel` lowercases titles again and calls lock-taking,
`Date()`-reading `Frecency.score` per match. `PanelView` uses eager `VStack` for
up to 50 rows and calls `NSWorkspace.icon(forFile:)` from `body` for each row.
Adaptive accent rasterizes a newly selected icon synchronously.

**Impact:** likely typing and arrow-key stutter on large app/command catalogs.
This needs Instruments confirmation, but the allocation and synchronous icon
paths are present.

**Change:** pre-normalize searchable fields when sources reload; score UTF-8 or
Unicode scalars without per-candidate arrays; take one frecency timestamp and
snapshot; use `LazyVStack`; cache workspace icons; compute accents off-main and
publish later.

**Proof:** XCTest performance baselines plus Instruments signposts for query to
rows and selection to frame. Compare allocations, main-thread icon time, and
p50/p95 latency before and after.

### 14. File search returns an arbitrary early slice

**Evidence:** `FileSearch.walk` stops once the first 500 matches are encountered
(`FileSearch.swift:220-235`), then ranks only that slice. Filesystem enumeration
order is not relevance order.

**Impact:** A better match later in the tree can never appear. Common short
queries are biased toward whichever directories enumerate first.

**Change:** walk to the visited/time budget while maintaining a bounded top-K
heap. Surface "partial results" when any budget is reached. Use a lightweight
index/FSEvents cache for repeated queries, with direct walking as the explicit
fallback.

### 15. Sparse streamed matches may not appear until the walk ends

**Evidence:** the interval flush is checked only when another match arrives
(`FileSearch.swift:350-359`). One early match followed by a long no-match walk
sits in `pending` until completion.

**Impact:** the UI can say "Searching files…" for seconds despite already having
a useful result.

**Change:** check pending flushes on a visited-entry/time stride independent of
new matches, or stream through an async timer/channel.

### 16. Direct filesystem walking is a poor default search engine

**Evidence:** every changed `find` query schedules a new recursive walk, capped
at 500,000 visited entries. System/external scopes can touch huge trees.
Cancellation is checked every 2,048 entries.

**Impact:** repeated disk and CPU load, battery drain, slow external-drive
access, and inconsistent results. Multiple cancelled walks can overlap until
they next poll.

**Change:** use a layered engine: cached app/file index with FSEvents updates,
Spotlight as a fast source where available, and direct walk only for excluded or
explicit "deep" scopes. Show source, progress, truncation, inaccessible roots,
and a Stop action.

### 17. App discovery is incomplete and stale

**Evidence:** `AppCatalog.searchDirectories` scans four fixed folders, despite
the plan naming LaunchServices. `AppSource` scans only at creation; no app-folder
watcher or workspace install/uninstall observer is wired.

**Impact:** apps on external volumes or unusual registered paths can be absent;
installs/removals after launch stay stale. The first scan also begins only when
the lazy panel stack is created.

**Change:** seed from LaunchServices/`NSWorkspace`, dedupe by canonical URL and
bundle ID, observe workspace launch/install/mount changes, and refresh off-main.

### 18. Broken commands disappear silently

**Evidence:** `CommandStore.scanErrors` is never presented. Entry edits can
rescan without changing the command value, and no command health surface exists.
Open/file/system action failures are mostly log-only.

**Impact:** users cannot tell why a command vanished or an action did nothing.

**Change:** add a Commands settings tab with loaded/invalid/disabled states,
origin, permissions, last error, reveal/edit/reload controls, and a panel error
row for a directly requested broken command. Show actionable HUD errors for
failed opens and system actions.

### 19. Duplicate command identity is ambiguous

**Evidence:** search IDs and dispatch use manifest name, while `Command.id` uses
directory path. `command(named:)` returns the first match. Multiple roots are
designed but no precedence or conflict UI exists. Equal-title sorting lacks a
total tie-break.

**Impact:** the row shown can dispatch a same-named command from another root.
That is a correctness and trust problem once extra roots ship.

**Change:** enforce unique names across active roots or carry canonical command
ID through `Item.Action`. Define root precedence and display conflicts.

### 20. Stored hotkeys accept unsafe modifier masks

**Evidence:** the recorder rejects bare and Shift-only chords, but
`Preferences.loadSummonHotkey` checks only `modifiers != 0`
(`Preferences.swift:486-495`).

**Impact:** hand-edited/corrupt defaults can register Shift+letter and intercept
normal typing globally.

**Change:** share one validation rule between recorder, persistence load, and
registration. Reject unknown modifier bits and invalid key codes.

### 21. Reset Appearance omits the typeface

**Evidence:** `Preferences.resetAppearanceToDefaults()` resets every nearby
appearance field except `panelTypeface` (`Preferences.swift:499-515`).

**Impact:** "Reset to Defaults" leaves a visible customization behind.

**Change:** reset typeface and add a regression assertion covering every field in
`Preferences.Default`.

### 22. AppKit work from command queues needs a thread audit

**Evidence:** clipboard, workspace open/activate, Accessibility prompting, and
System Settings opening are invoked from the JavaScript queue in
`InvoqueBridge`, with no abstraction separating thread-safe work from
main-affine UI/activation calls.

**Impact:** unclassified calls risk UI work off the main actor or deadlocks from
synchronous main hops inside JS callbacks.

**Change:** classify every bridge call. Hop UI and AppKit activation work to
MainActor; keep disk/network/process work off-main. Avoid synchronous main hops
that can deadlock a JS callback.

**Status:** investigation item, not a confirmed defect.

### 23. Manifest validation is too permissive

**Evidence:** no validation enforces non-empty title, one-token non-empty filter
trigger, argument names/types, duplicate permissions/keywords, reasonable field lengths,
or a real SF Symbol. `GeneratedCommandValidator` can accept `obj.run = ...` or a
non-callable `run = 3` as an entry point.

**Impact:** schema-valid commands can render blank rows/icons, be impossible to
trigger, or fail only on first run.

**Change:** make manifest validity represent actual runnable states. Compile the
entry as a Program, tighten entry-point detection, and fall back visibly when a
symbol is unavailable.

## P0 distribution gate: fix before any public release

### 24. Releases are unsigned and unnotarized

**Evidence:** `.github/workflows/release.yml` ad-hoc signs and explicitly tells
users to bypass Gatekeeper. This conflicts with the documented Developer ID and
notarization goal.

**Impact:** users must disable a core trust check for an app that executes
generated code. Installation friction and provenance risk block a public stable
release.

**Change:** use Developer ID Application signing, hardened runtime, notarization,
stapling, signature verification, and a documented secret-rotation process.
Never suggest recursively removing quarantine as the primary install path.

## P1: remaining release and supply-chain issues

### 25. The updater does not verify release authenticity

**Evidence:** the release ships `SHA256SUMS.txt`, but `UpdateDownloader` trusts
the downloaded asset and only applies quarantine. It also reveals rather than
installs, so the flow is incomplete.

**Impact:** a same-channel checksum detects corruption, not a compromised
release. A bespoke replacement flow also risks installing the wrong team,
bundle, or version.

**Change:** make code-signature verification the trust anchor. Fail closed unless
Developer ID team, bundle ID, and version match after mounting or extraction.
Treat `SHA256SUMS.txt` only as corruption detection. Prefer a maintained updater
such as Sparkle with EdDSA-signed appcasts over a hand-rolled installer.

### 26. PictKit tracks a mutable branch

**Evidence:** the Pict `XCRemoteSwiftPackageReference` in `project.pbxproj`
tracks `main`, and no `Package.resolved` is committed.

**Impact:** builds are non-reproducible; an unrelated or compromised upstream
push can break or alter CI/release artifacts.

**Change:** pin a reviewed tag or exact revision and commit resolution state.
Automate deliberate dependency updates.

### 27. A tag can publish before main CI passes

**Evidence:** the release check verifies only that the tag is reachable from
main. It does not verify a successful CI check for that commit and the release
job does not rerun tests.

**Impact:** a tagged revision can publish despite a failing or still-running
build and test job.

**Change:** make release depend on a successful workflow for the exact SHA or
run the full test/icon gates again before packaging.

### 28. JSC performance entitlement and documentation disagree

**Evidence:** `PLAN.md` says `com.apple.security.cs.allow-jit` is added with the
runtime, but `Invoque.entitlements` is empty.

**Impact:** interpreter mode may be acceptable, but the current security and
performance choice is accidental, undocumented, and unmeasured.

**Change:** benchmark command/filter latency under hardened release signing.
Either add the entitlement with rationale or document interpreter-only as the
security choice.

## UI, layout, and accessibility

### What already works

- The panel has a coherent hierarchy: query, list/card, footer.
- AppKit owns focus and window behavior instead of relying on fragile SwiftUI
  focus in a nonactivating panel.
- Themes include material, gradient, text, corner, typeface, adaptive accent,
  presets, retro decoration, import/export, and a live preview.
- Selected text contrast considers compositing rather than raw highlight color.
- Reduce Motion is wired for row animation.
- Detached file results preserve the streaming session and remain actionable.

### Problems

1. **Empty launch is empty.** An empty query shows instructional copy, not recent,
   pinned, or frequent actions. A launcher should be useful before the first
   keystroke.
2. **Single click executes.** Mouse selection and activation are conflated. This
   is especially unsafe for system actions. Single click should select; double
   click or Return should execute.
3. **No action panel.** There is no discoverable Copy Path, Reveal, Open With,
   Pin, Block, Inspect Command, Edit, or alternate action surface. Hidden chords
   in a footer do not scale.
4. **No command capability badge.** The plan promises one; `ResultRowView` has no
   permission metadata.
5. **No argument editor.** See issue 9.
6. **No loading state for action commands.** The panel looks idle during a slow
   run and allows duplicate submits.
7. **Fixed 680x440 geometry.** It is not configurable and may clip or feel sparse
   with unusual fonts, larger accessibility text, or compact displays.
8. **Footer copy is dense.** One centered string combines up to five actions. It
   can wrap or crowd custom fonts. Use separated keycaps and context-sensitive
   action labels.
9. **Decorations draw over content.** The top-corner overlay does not reserve
   header space. Large stripes/balls can compete with or cover the query.
10. **Glass choices collapse on older macOS.** Liquid, clear, and regular variants
    are mostly the same popover fallback, while labels imply distinct rendering.
11. **Maker theme leakage.** The manifest title uses system `.primary`, and its
    native inline fields use the system font even on custom solid themes.
12. **Selection can become invisible.** Highlight opacity can reach zero; no
    outline or alternate selected-state cue remains.
13. **No Increase Contrast support.** Secondary text opacity and icon-derived
    colors can fall below useful contrast.
14. **No panel entrance animation.** The plan specifies a small Reduce-Motion-aware
    drop. Current show/order is abrupt.
15. **Icon fallback work is synchronous.** It also causes visual popping when
    Pict artwork lands.
16. **The 16/32 px app icon is over-detailed.** The actual asset is squircle-clipped,
    and the separate status mark is readable, but the wordmark, stripes, grain,
    and confetti collapse at small sizes. Supply hand-tuned 16/32 variants with
    the cyan mark and two or three flat colors. Consider an optional monochrome
    template status icon for menu-bar consistency.
17. **No localization.** User-facing copy is hard-coded English.
18. **Accessibility needs manual proof.** Verify VoiceOver order, selected state,
    keyboard focus, Full Keyboard Access, larger text, RTL, Increase Contrast,
    Reduce Transparency, and multi-display/full-screen behavior.

## Missing product features, ordered by leverage

| Roadmap rank | Feature | Narrow first slice |
|---|---|---|
| P1 | Commands management | Loaded/broken/disabled list, reveal, edit source, permissions, rescan |
| P1 | Command source inspector and revision diff | Read-only manifest/source viewer in Maker and action panel |
| P1 | Argument entry | Text arguments, required validation, recent values |
| P1 | Action panel | `⌘K`, searchable actions, alternate action shown per row |
| P1 | Empty-query home | Pinned, recent, frequent, and last-used entries with privacy controls |
| P1 | Onboarding | Explain hotkey, menu item, command folder, Maker key, and permissions |
| P1 | Signed update/install | Verify, replace, relaunch, rollback |
| P1 | Permission center | Capability explanations, grants, revoke, Accessibility status |
| P1 | Command edit/rollback | `edit command`, visual history, restore revision |
| P2 | Quick Look | Space previews files; command rows open X-ray instead |
| P2 | Universal actions / Instant Send | Send selected Finder text/files into commands |
| P2 | Clipboard history and snippets | Local, encrypted-at-rest option, exclusions, retention controls |
| P2 | Quicklinks | Named URLs with placeholders and selected-text input |
| P2 | Window switching/management | Search windows, move/resize presets, no screenshots required |
| P2 | Emoji, symbols, colors, UUID/date tools | Small built-ins with copy/insert actions |
| P2 | Rich calculator | Units, opt-in rates with source/refresh time, percentages, date math |
| P2 | App aliases and direct hotkeys | Per-entry aliases/hotkeys in Settings |
| P2 | Better file mode | Editable detached query, Open With, copy path, parent navigation |
| P2 | Command observability | Last run, duration, logs, timeout count, health badge |
| P2 | Importers | Raycast script metadata and Alfred Script Filter adapters |
| P3 | Data-declared command views | Native list/detail/form schema, no embedded web runtime |
| P3 | Optional on-device Maker | Apple Foundation Models/local endpoint with privacy label |

## Delightful ideas

These fit Invoque's plain-file, keyboard-first identity instead of copying a
large extension store.

### Command X-ray

Press Space on a command row to open X-ray, which is that row's Quick Look. It
shows source, declared capabilities, generated provenance, last diff, last
runtime, and last error. Highlight each `invoque.*` call beside the capability
it requires. File rows keep the standard Quick Look.

### Rehearsal mode

Before a generated command's first real run, offer a dry rehearsal. Bridge
methods record intended effects such as "would open URL", "would write
clipboard", or "would run shell" and return fixtures. Every result must carry an
unmistakable "simulated" label. Discard fixtures after the rehearsal: never
cache them, never persist them to history/logs, and never count them toward
command health stats. This cannot perfectly simulate shell/network, but it
makes common generated commands reviewable.

### Universal action stack

A lightweight stack holds Finder selections, clipboard text, or result rows.
`⌘Enter` sends the stack into any compatible command. It combines LaunchBar's
Instant Send and Alfred's File Buffer with Invoque's generated commands.

### Ghost completion

Show the top result as faint inline completion in the query. Tab accepts its
remaining title; Return still executes. This makes learned abbreviations feel
instant without moving rows.

### Slow-command quarantine

Measure every command. After repeated timeouts, show a small snail badge and
stop running it from the hot path. "Why slow?" opens logs and suggests moving
work async. Make the badge playful but the behavior deterministic.

### Undo capsule

After reversible actions, leave a small timed capsule: restore prior clipboard,
reopen the last closed panel state, unpin/reblock, or restore a Maker revision.
Clipboard snapshots must obey clipboard-history app exclusions and retention
rules; when an exclusion or retention rule blocks the snapshot, omit clipboard
restore from the capsule instead of restoring stale data. Never claim undo for
restart, shell, or deletion.

### Theme pulse, restrained

Let the selected icon tint only a thin edge light or search glyph, not the whole
row. It keeps adaptive personality while reducing the current large-color bloom.
An optional 100 ms "summon spark" can use the theme accent and honor Reduce
Motion.

### Make from no-result

When a query has no match, offer a last row: `Make a command for “…”`. It must be
explicit and show that it will call the configured model, never trigger on
Return by default.

### Command postcards

Export a command as a small signed/read-only preview bundle containing its
manifest, source, screenshot-free result sample, and permission summary. Import
first verifies the manifest digest and a signature from a public key the user
explicitly pinned by fingerprint, rejecting unsigned, unpinned, or mismatched
bundles. It then opens X-ray; execution remains a separate user action. Export
signs with the author's locally generated key and displays its fingerprint;
recipients may pin a fingerprint only after confirming it out of band — never
from the bundle itself. Re-pinning is supported, and already-imported postcards
signed by a retired key surface a visible warning.

### Tiny optional personality

Theme-specific empty states can rotate concise text art or facts after a delay,
paused entirely under Reduce Motion. No animation while typing, no sound by
default, and never obscure status/errors.
The retro themes can feel authored without making the core launcher noisy.

## Recommended implementation sequence

Each item is intended as a focused branch and PR.

1. **`fix/system-action-confirmation`**: trusted confirmation state and tests.
2. **`fix/shell-lifecycle-budgets`**: process cancellation and output caps.
3. **`fix/command-data-containment`**: symlink regression tests, then canonical
   containment in loader/writer/bridge.
4. **`fix/stale-command-completions`**: invocation ticket for every result shape.
5. **`fix/reduce-transparency`**: opaque glass fallback and accessibility test.
6. **`perf/instant-first-summon`**: off-main command warm-up, remove duplicate scan,
   add signposts.
7. **`perf/lazy-cached-results`**: lazy rows, icon cache, async accent, query
   benchmark.
8. **`fix/file-search-top-k-streaming`**: global top-K and independent timed flush.
9. **`feat/maker-source-review`**: source tabs, permission call sites, revision diff.
10. **`feat/command-arguments`**: compact argument editor.
11. **`feat/action-panel`**: row actions and capability inspection.
12. **`feat/commands-settings`**: invalid/disabled commands and roots.
13. **`chore/reproducible-dependencies`**: pin PictKit and resolution state.
14. **`release/developer-id-updater`**: signing, notarization, checksum/signature
    verification, and tested-SHA gate.

## Validation plan

Before a stable release:

- Cold/warm hotkey-to-first-frame signposts on Intel and Apple Silicon.
- Typing p50/p95 with 1,000 apps/commands and adaptive accent on/off.
- File search on large APFS home, whole disk, slow external SSD, and denied TCC
  folders; verify cancellation and partial-result messaging.
- Resource-abuse tests for JS loops, shell children, fetch bodies, logs, storage,
  and result arrays.
- Symlink and source-swap tests at every command file boundary.
- Manual system-action confirmation and Accessibility paste flows.
- Maker never calls the model on Return when no result is present; an explicit,
  visible confirmation is required.
- Command postcard import rejects unsigned, unpinned, or digest-mismatched
  bundles; X-ray shows only contents verified by a user-pinned public key.
- VoiceOver, Full Keyboard Access, larger text, Reduce Motion, Reduce
  Transparency, Increase Contrast, RTL, multiple displays, and full-screen
  Spaces.
- Developer ID signature, notarization, quarantine, update verification,
  replacement, relaunch, and rollback from a clean Mac account.
