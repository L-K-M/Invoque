# Astra review of Invoque

Reviewed 2026-09-26, baseline `f9b9c9d` on `origin/main`. This document was
written before implementation. Findings below are independent of other models'
reviews and PRs. `ANALYSIS.md` will carry the consolidated, current backlog;
this file preserves what the review actually found.

## Assessment and evidence

The foundations are good: a nonactivating AppKit panel with native text input,
pure matching/ranking logic, capability-gated JavaScript, inspectable command
files, meaningful tests, and system frameworks instead of a large dependency
stack. The shipped code is substantially beyond AGENTS.md's "early
implementation" description. The greatest opportunities are lifecycle
correctness, honest progress/error states, and reducing synchronous work in
the interaction path, followed by simplifying presentation.

This is a source audit of panel lifecycle, search, indexing, commands, Maker,
settings, themes, accessibility, and CI. Confidence is stated per finding.
A standalone JavaScriptCore probe reproduced A12. Native UI inspection via the
computer-use connection timed out; no screenshot, animation, VoiceOver,
multidisplay, or frame-time verification is claimed. Performance candidates
below require measurement, not assumptions about their cost. References are
repository-relative and refer to the baseline. Existing tests are evidence of
coverage, not proof that untested boundaries work.

## Priority findings and implementation tickets

### A01. Invisible launcher: eliminate unsafe window opacity transitions

**High priority, plausible root cause of the reported symptom, not reproduced.**
`Panel/PanelController.swift:140-291` animates the same window's `alphaValue`
and frame for both show and hide. Generation checks suppress an old hide
completion's `orderOut`, but do not cancel its animation writes. The ordinary
already-visible path directly sets alpha to one, which the code itself notes
elsewhere does not reliably detach an animation. `isVisible` remains true for
an ordered, fully transparent window, and `makeKey()` can still hand it typing.
This explains the symptom class without proving the exact observed sequence.

Prefer immediate, opaque window ordering for a keyboard launcher: every show
sets alpha to one, lays out on the current display, orders front, then focuses;
every hide orders out immediately. Keep row/theme effects independent of the
window's visibility. This also avoids holding input during a fade and removes
150 ms of presentation latency. Do not add increasingly complex overlapping
animation state. Update PLAN's drop-in-animation promise.

Acceptance: rapidly alternate hotkey/Esc/click-away, summon during dismissal,
repeat after sleep/display changes/Spaces/fullscreen, and toggle Reduce Motion.
After every summon the panel is visible, opaque, on-screen and typeable; after
dismissal it cannot consume input. Verify on an actual GUI session. If opacity
is healthy but blank rendering persists, instrument frame, alpha, key/visible
state, screen ID and content bounds (never query contents), then investigate
hosting/glass rendering separately.

### A02. Stale action results dismiss a newer launcher session

**Confirmed control-flow bug.** `PanelController.swift:302-340` checks query and
session only for `.items`. An old run's error, `.title`, or `.void` calls hide
against a new summon. Gate all presentation effects by invocation and panel
session; decide explicitly whether a result from an edited query deserves a
nonintrusive notification. Regression: delay an action, dismiss, reopen and
search, then finish every output/error variant; the new panel must remain.

### A03. Forced web search loses keyboard selection

**Confirmed.** `Panel/PanelModel.swift:420-428` assigns results without the usual
selection normalization. Move to the third normal result, type `web cats`, and
the single web row has no valid selection, so Return does nothing. Route all
result replacement through the same selection rule; test transition from a
nonzero selection, blank web text, refresh and submission.

### A04. Remembered async searches do not reliably resume

**Confirmed.** `PanelModel.swift:1052-1074` cancels work on hide, but reset with
an unchanged retained query does not refresh. Reopen after dismissing a pending
file/filter search and see canceled or partial results indefinitely. Resume
appropriate query work on summon, keeping stale callbacks invalidated. Test
file and filter queries with a deterministic suspended provider and no edit.

### A05. Changing file-search scope does not restart an identical query

**Confirmed.** `AppDelegate.swift:251-252` requests refresh; PanelModel's
`scheduleFileSearch` (`:709`) rejects an unchanged keyword/text. Include scope
or a refresh generation in session identity, or expose explicit invalidation.
Test switching scopes while a scan is pending and after it completes; reject
old results and show files from the new scope without changing the query.

### A06. Clipboard search does not implement its advertised history mode

**Confirmed.** `Search/Sources/ClipboardSource.swift:49-66` recognizes `clip
term`, but generic SearchModel matches the entire prefix plus term against
content followed by appended keywords. Ordinary content matches disappear.
Generic ranking also reorders newest-first history by title/match rather than
recency. Give clipboard mode a parsed payload query and chronological ranking,
with integration tests at PanelModel/SearchModel level. Bound entry bytes as
well as count; compute/truncate previews once rather than replacing newlines
across an entire copied document on each search. Publish polling changes into
an open history list. Expose pause/clear and explain retention if absent.

### A07. File streaming progress is neither time-bounded nor exhaustive

**Confirmed.** `Search/FileSearch.swift:352-359` checks flush elapsed time only
when another match arrives. An early sparse hit can wait until completion.
Also the first 500 matches stop traversal (`:232,:359`): later exact matches,
pins and later roots never reach ranking. Flush buffered progress from the
visit loop or a controlled timer; keep best bounded candidates while honoring
an explicit visit/time budget. Return completion metadata (complete, canceled,
limited, unreadable locations) and show a truthful partial-results status.
Tests: one early match followed by many nonmatches, late exact/pinned match,
and a later scope root. Do not remove all budgets or flood main with updates.

### A08. Main-thread I/O and cold icon work need latency budgets

**Source-confirmed work placement, unmeasured impact.** `PathSource.swift:56-64`
synchronously checks ancestors during typing, including potential network
mounts. `WorkspaceIcons` fallback plus `AdaptiveAccent.swift:29-74` TIFF/CI
conversion occurs from SwiftUI row construction. `MakerModel` performs edit
loading, validation, saving and rescans on MainActor (`:182,:188,:320,:435-447`);
its recursive enumeration walks data/history before filtering them out.

Measure cold/warm summon, per-keystroke p50/p95/p99, arrow repeat, first icon,
and directories on slow/disconnected volumes. Move disk/provider work behind
cancellable workers with bounded caches; publish only current generations.
Decode/downsample icons and calculate accent once off the interaction path.
Avoid walking runtime/history trees. Add signposts containing counts/timings,
never clipboard text, prompts or secrets. Target a frame budget at both 60 and
120 Hz and demonstrate measured improvement before adding cache machinery.

### A09. First summon can launch a web fallback before apps are indexed

**Confirmed ordering risk, timing reproduction outstanding.** AppDelegate lazily
creates the controller/AppSource on first summon (`:21,:262`); AppSource
returns an empty catalog until its async scan publishes. Warm the lightweight
catalog at launch, or expose indexing status and prevent accidental fallback
submission during that short gap. Test a delayed catalog and fast `safari`
Return before/after publication. Never make launch block on indexing.

### A10. Command hot reload misses content and inode changes

**Confirmed.** `Commands/CommandStore.swift:213-217` compares Command values
without entry content and rebuilds watchers only if path arrays change.
JS-only changes need not refresh an active filter; atomic editor saves leave
vnode watchers on the old inode. Re-arm replaced targets and publish a content
revision. Exclude `data/` and `history/` from the recursive watch budget
(`:254-270`) and prioritize manifest/entry; storage writes currently cause
unnecessary rescans and history can consume the 256-watch cap. Test repeated
atomic replacement followed by in-place save and live-filter refresh.

### A11. Command identity and edit destination disagree

**Confirmed.** Command.id is directory-based, but CommandSource uses name-based
row/actions (`:75-78`), `command(named:)` selects the first sorted match, and
MakerModel saves edits via a fixed primary-root writer (`:435`). Duplicate
names collide; editing secondary-root or differently named directories can
create a shadow command. Carry canonical directory identity through lookup,
actions, disable/pin state and edit sessions; preserve the original edit
destination and define duplicate display/disambiguation. Test two roots with
equal names and edits where directory basename differs from manifest name.

### A12. Valid lexical JavaScript entry points fail at runtime

**Reproduced with JavaScriptCore.** Validator accepts `const run = …`
(`Maker/GeneratedCommandValidator.swift:137-142`). Runtime verifies lexical
`typeof run`, then retrieves a global-object property
(`Commands/JSRuntime.swift:168-180`). Top-level const/let bindings are not
properties, so the call fails on undefined. Resolve the callable in JavaScript
lexical scope, preserving function/async/export-default forms. Tests must
actually observe results from const/let/async arrow functions, not just absence
of an error; retain missing-entry diagnostics.

### A13. Invocation timeout does not close all side-effect paths

**High priority, confirmed missing lifetime ownership.** `InvoqueBridge` fetch
callbacks (`:309-323`) can still run resolve/reject after timeout/cancellation;
FetchTaskRegistry has no terminal state. JSRuntime uses a continuation without
Swift task cancellation propagation (`:68`). Superseded filter tasks can keep
network/context work alive. Shell (`bridge:475-505`) is not terminated when the
runtime reports timeout. Console and PipeDrain buffers are unbounded
(`CommandLog:16-23`, `bridge:690-699`).

Create one invocation lifetime shared by completion, cancellation, fetches,
shell and bridge callbacks. Atomically mark terminal, cancel resources, reject
late registration and suppress queued callbacks before entering JS. Bound
captured bytes with explicit truncation diagnostics. Decide process-group
termination policy for shells; do not merely kill the waiter. Tests use local
controlled endpoints/processes, cancellation barriers and side-effect markers
to prove nothing happens after termination. Separate memory/output budgets
from CPU deadline. Avoid claiming JS is sandboxed just because modules gate it.

### A14. Network state and consent boundaries need explicit decisions

The bridge's shared ephemeral URLSession (`:39-46`) retains shared in-memory
cookies across invocations/commands; "ephemeral" does not mean isolated.
Use per-invocation policy or disable cookie state unless explicitly designed.
Test two commands against a local cookie endpoint. Existing PLAN already
acknowledges clipboard.read + network exfiltration and consent hash vs execution
TOCTOU/auxiliary-file gaps. Bind consent to the exact bytes executed and decide
whether sensitive read + egress needs first-run consent. These change the
public API/security contract: update PLAN, schema and Maker prompt together,
with migration tests. Do not silently broaden grants.

### A15. Maker revision snapshots lose auxiliary file history

**Confirmed.** `Maker/CommandWriter.swift:237-285` snapshots manifest/entry but
can overwrite additional authored files without retaining old contents.
Snapshot the complete authored file set, excluding data/history, before a
transactional update. On failure restore all touched files, and make user
rollback restore deletions too. Test nested extras, removed files, simulated
mid-write failure and data preservation. Follow with an inspectable revision
browser and explicit Restore action.

### A16. Keychain writes can fail silently and discard the API-key draft

**Confirmed.** `Maker/Keychain.swift:45-99` discards write/delete OSStatus;
`MakerSettings.apiKey` cannot surface failure; Settings clears the draft
(`SettingsView.swift:277-284`). Return actionable typed errors, keep the draft
on failure and show success only after persistence. Test injected denied,
locked, unavailable and update failures. Never log the key itself.

### A17. Theme contrast and transparency rules are incomplete

**Confirmed math defects.** `Model/ColorHex.swift:67-70` uses gamma-space luma:
opaque #00FF00 chooses white, only about 1.37:1 contrast. Compare actual black
and white contrast using linearized sRGB luminance. `composited(:42)` ignores
intrinsic alpha; multiply by configured opacity. `PanelBackground.swift:51-55`
sets outer opacity to one under Reduce Transparency but leaves alpha embedded
in #RRGGBBAA fills. Force opaque tint and gradient endpoints in that mode.
Test saturated colors, transparent highlights and both gradient stops. Treat
glass/wallpaper and varying gradients as estimates, not guaranteed contrast.

### A18. Action hints, alignment and dense cards need polish

**Confirmed source behavior; clipping needs visual verification.** PanelView
footer calls copy actions "open" (`:380-386`) and can accumulate roughly 90
characters into a single line (`:325-336`). Derive verbs from actions; prioritize
primary/secondary hints and put less-common shortcuts behind a discoverable
actions/help affordance. ResultRowView source badges reserve width only for
durable rows (`:106-114`), misaligning mixed-source titles. Reserve one shared
column or remove the tiny badge in favor of a clear source subtitle.

Maker draft title omits theme foreground (`MakerView:202-203`), so dark solid
themes in system Light mode can have dark text. Permission badges in Maker
and Commands settings are single nonwrapping HStacks; use a wrapping layout
or summary + expandable list. Test long names, all permissions, custom large
fonts and both system appearances. Avoid visual churn while typing.

### A19. Error/status semantics deserve an audit

`invoque.notify` promises visible notification in SystemPrompt (`:70`) but only
logs in the bridge (`:117-122`). Implement a documented delivery surface or
correct all contracts. `filterRunIsPending` uses a task that is not nilled on
completion (`PanelModel:575,632-646`), so pending state lies. Corrupt storage is
silently overwritten by documented existing test behavior
(`JSRuntimeTests:333-351`); preserve a readable backup and surface recovery.
Use inline, selectable errors for persistent failures and brief HUDs for
success; a 1.6-second truncated toast is not an adequate troubleshooting UI.

## Product and visual direction

Keep the launcher fast and calm. The signature should come from spacing,
typography and restrained color, while the existing retro themes remain
available as deliberate personality choices. Additions should not displace
ordinary app launching or trigger generated code implicitly.

- **Contextual action palette.** One discoverable shortcut reveals Open,
  Reveal, Copy path/URL/value, Pin, Block, and command Inspect/Edit. Use the
  selected row's real capabilities, preserve focus/selection on close, and
  expose the same actions to VoiceOver. Acceptance: all advertised actions
  work on each source, no disabled mystery shortcuts or footer truncation.
- **First-run prompt chips.** An empty launcher teaches `find report`, `web
  question`, `clip`, `make …`, arithmetic and shortcuts. Keyboard accessible
  chips insert a query without executing it. Once history exists, top hits
  win and help stays accessible. No network call for onboarding.
- **Explain this result.** An optional action shows matching title/keyword,
  pin and recent-use reasons. Add an Unpin/Undo block action with a clear
  route back; debugging ranking should not require inspecting defaults.
- **Quick Look with Space.** Preview eligible files without changing launch
  semantics, lazily loaded and cancelable; Escape returns to the same row.
  File packages, missing files and large/network files get safe fallbacks.
- **Theme contrast inspector.** Preview light/dark appearances, long results,
  permission/Maker cards, Reduce Transparency and selection colors. Offer
  automatic readable text and a one-click reset. Add density/text-size
  controls before adding more decoration. Keep geometry stable across modes.
- **A small optional personality.** A tiny summon glyph, a satisfying copy
  checkmark, or an opt-in "surprise me" local generator can be delightful.
  Respect Reduce Motion; never animate the whole window through invisibility,
  play unsolicited sounds, or substitute novelty for a real result.
- **Command revision workshop.** Side-by-side source diff, permission delta,
  Test, Save and Restore make the Maker trustworthy. No auto-execution on
  save. Back it with complete snapshots (A15) and correct identity (A11).
- **Privacy controls for history.** Pause/clear clipboard capture, per-item
  removal, byte/time retention caps, and an explanation of what stays local.
  Keep secrets out of query logs, diagnostics and generated prompts by default.
- **Compact mode after measurement.** A smaller empty/top-hit card with a
  stable maximum result viewport could feel nimble, but only if expansion
  never moves the selected target or fights screen bounds. Prototype and
  verify keyboard/VoiceOver behavior before changing fixed geometry.

## Delivery plan

First prioritize A01, A03-A05, A12 and A17 as focused, independently reviewable
PRs. Record all other work as actionable backlog rather than expanding those
patches. Keep implementation PRs open for the owner to merge. Inspect only
this task's PRs, their CI, and their GLM feedback. Stop after two completed
rounds without applicable important findings, or report a GLM timeout/review
gap as such. Do not fabricate code changes to solicit another review.

Consolidate into ANALYSIS.md on current main without deleting unique existing
ideas. Remove actually completed work from the active backlog; open PRs remain
pending, linked by status, until merged. Correct obsolete documentation only
where the current source establishes completion. Preserve uncertainty and
explicit acceptance criteria for future agents.

## Additional follow-through from the audit

- Search matcher preparation: FuzzyMatcher creates repeated character arrays
  per candidate (`:87-92`); prepare the query once and benchmark normalization
  reuse before optimizing. Include Unicode/diacritic behavior in explicit tests.
- A blocked directory's children remain in an already-streamed file list,
  while a fresh scan prunes its subtree. Share the same path containment rule
  for live reshaping and fresh scans; test parent/child/sibling boundaries.
- Maker provenance: saving an edit without generation replaces original
  provenance with `edit <name>` and an empty or previous-session model;
  reset does not clear lastUsedModel. Preserve provenance until generation
  actually creates a new revision; test switching provider/session and saving
  untouched drafts.
- Accessibility audit: verify selected-result announcements while text retains
  focus, detached-result AXPress parity, and permission-card navigation.
  Appearance preview disables hit testing but is not accessibility-hidden;
  mark the inert demo appropriately. These need VoiceOver verification.
- Settings roadmap: AI/Updates deserve focused sections; implement the planned
  Permissions view, editable command roots, enable/disable and grant revocation.
  Settings currently offers General/Appearance/Commands. Explain hotkey failure
  inline and preserve the last working binding.
- Duplicate app names should show distinguishing origins only when necessary;
  shorten long paths intelligently and expose the full target on demand.
- Optional app aliases and query-specific learning can improve repeated short
  searches. Keep a reset path and deterministic ranking tests.
- Tab path completion should show the actual existing ancestor versus an
  unfinished typed path. Running-app badges and supported New Window actions
  belong in the contextual action surface.
- A bounded, explicit result shelf may complement Quick Look for collecting
  items across searches. Persist inspectable entries and keep it out of
  ordinary ranking unless requested.
- Command argument prompts can use the existing manifest schema instead of
  relying on opaque query syntax. Pair running/cancel states with bounded,
  inspectable execution history, duration and logs.
