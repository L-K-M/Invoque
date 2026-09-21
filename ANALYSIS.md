# Invoque — Analysis & Future Work

High-quality, shovel-ready ideas for future development. Each item is
independently implementable and documented with enough context for an LLM
to pick it up.

Provenance: this document merges the pre-existing ANALYSIS.md (bugs, perf,
quality, features, UX, creative lists) with the `muse.md` and `glm.md`
full-codebase reviews (2026-09-21, `main` @ `bafb9d9` v0.2.0), plus the
independent `sol.md` static audit (PR #52, baseline `e8b96b8`) and the
`swe.md` review (2026-09-21 — bugs, perf, features, UX, theming, delight;
its implemented items are recorded below). Duplicate
entries are consolidated, not duplicated; open fixes are tracked under
`Recently implemented`. Nothing was dropped — follow-ups the reviews declined
or deferred live under `Review follow-ups`.

---

## Recently implemented (review round, PRs open for maintainer review)

- ✅ Appearance reset restores the typeface — PR #28. `resetAppearanceToDefaults` omitted `panelTypeface`, so Reset left a stale font. One-line fix + test coverage incl. a vacuous-default guard (round-2 review).
- ✅ Maker feedback clears stale consent — PR #29. `sendFeedback` left a pending `permissionRequest` armed against the old draft, wedging every later Test. Clears with the draft + regression test. Review's `start()`-path worry refuted with evidence (`start` → `reset()` already clears).
- ✅ HUD over fullscreen + clipped corners — PR #30. Added `.fullScreenAuxiliary` (matching `LauncherPanel`) and `masksToBounds`, plus `.continuous` corner curve (round-2 review). The `ignoresMouseEvents` suggestion was already present (`HUD.swift:65`).
- ✅ Escaping command entry throws instead of trapping — PR #33. `Command.init` used `precondition` on untrusted manifest input (persistent crash on every launch/rescan). Throws the validator's existing `entryEscapesDirectory`; store reports it per-directory as `ScanError`. Direct + scan-level + symlink-escape regression tests, shared fixture, documented `- Throws:` (round-2 review).
- ✅ Arch hints match whole tokens; fractional dates parse — PR #34. `intel` fired on `IntelligentApp.dmg`, `x64` on `x6400`; hints now match contiguous alphanumeric-token runs (`x86_64` still spans its separator). `published_at` tries a fractional-seconds formatter first, falls back to plain, with an exact-instant test. CI caught and fixed a parameter-shadowing compile error in review.
- ✅ Frecency top hits on the empty query — PR #27 (`glm.md` F1). An empty panel listed only a hint; it now leads with the user's most-launched entries (best score first, capped at 9, blocks honored, only `recordSelection`'s durable namespaces; zero-state users still see the hint). Eligibility extracted to `SearchModel.isFrecencyEligibleID` so the rail and the trainer can't drift. PLAN §3 documents the new empty-query contract.
- ✅ Typed/pasted URLs open directly — PR #31 (`glm.md` B1). Only the web fallback existed, so ⏎ *searched the engine for the URL*. `URLSource` resolves a whole-query http(s) address (strict parse on macOS 14+, no raw whitespace) and pins its `url:` row first alongside `path:`; the search row stays beneath.
- ✅ ↑ query-history recall — PR #35 (`glm.md` F2). `QueryHistory` (50-entry ring, submits only, trimmed, dedupe-move-to-front) + Alfred-style ↑-at-top-row/back, ↓-forward recall in `PanelModel`, with edit/submit/reset exits. Unwired history keeps the old wrap behavior exactly.
- ✅ ⌘C copies the selected row — PR #40 (`glm.md` F3). Path for file/app rows, address for URLs, payload for copy rows, title otherwise; a field text selection keeps the normal copy; consent/maker cards make it a no-op.
- ✅ Matched-text highlighting — PR #43 (`glm.md` V1). The contiguous query occurrence renders semibold in titles (prefix/infix tiers; fuzzy highlights nothing rather than approximating). `PanelModel.highlightQuery` (live query / scan text / nil in filter mode) feeds panel + detached window.
- ✅ Hover fill + compact subtitle-less rows — PR #46 (`glm.md` V2+B4). Hovered unselected rows show the selection fill at 45 % opacity; empty subtitles no longer render a blank caption line.
- ✅ Number-base conversions — PR #47 (`glm.md` F7/D4). `255`/`0xFF`/`0b1010`/`0o17` answer in the other bases (hex/dec headline, all three in the subtitle, ⏎ copies); `calc:`-namespaced id keyed by value; decimal needs ≥2 digits so a lone digit stays an app search.
- ✅ Generators: `uuid`, `now`, `flip`, `roll`/`dN` — PR #49 (`glm.md` D2). Exact-keyword instant answers, values fresh per query, ⏎ copies; fully injectable for deterministic tests.
- ✅ Workspace-icon cache — PR #51 (`glm.md` P1). Result rows' fallback icon goes through a bounded `NSCache` (`WorkspaceIcons`) instead of a fresh `NSWorkspace.icon` call per body evaluation; nonexistent paths stay uncached. The async pipeline below remains open.
- ✅ Command-owned path containment — PR #54 (`sol.md` P0). Loader, bridge, and Maker reject symlinked `data`, `storage.json`, manifests, entries, and generated destinations; regular-file checks also reject FIFOs and devices. CI and two review rounds passed.
- ✅ Opaque Reduce Transparency surface — PR #56 (`sol.md` P1). Glass materials switch to an opaque semantic base plus theme wash instead of retaining a backdrop view. Runtime compositing and screenshots on macOS 13/15/26 remain manual proof.
- ✅ Generated-source review — PR #58 (`sol.md` P1). Maker exposes selectable, copyable contents for every generated file before Save, with stable ordering, collision handling, regeneration fallback, and VoiceOver state. Revision diff and call-site highlighting remain open.
- ✅ Consequential system-action confirmation — PR #61 (`sol.md` P0). Restart, shutdown, and home Trash require a trusted card plus button or ⌘Return; repeated plain Return stays neutral; lock and sleep remain immediate. Escape dismisses only the card. CI passed; manual mouse/keyboard proof remains.
- ✅ Lazy result rows — PR #62 (`sol.md` P1). Panel and detached lists use `LazyVStack`; long-list scrolling and layout still need visual macOS QA.
- ✅ Initial command scan off main — PR #66 (`sol.md` P1). Startup command I/O no longer blocks first panel construction, duplicate scanning is removed, and superseded scans cannot commit stale snapshots. CI passed; hotkey-to-first-frame signposts remain.

---

## Bugs to Fix

### CalculatorSource integer overflow
`CalculatorSource.swift:283-284` — `Int64(value)` will trap on values between `1e15` and `Int64.max` (~9.2e18). Use `Int64(clamping:)` or check against `Double(Int64.max)`.

### Old command completions can dismiss a new interaction
`PanelController.runCommand` gates only `.items` on query and panel session; an older error, `.title`, or `.void` completion still hides a newly summoned panel and may show a stale HUD. Issue each invocation a generation/session/query ticket and gate every completion shape. Add hide/resummon, query-change, newer-command, and repeated-Return regressions; show a running state and suppress duplicate side effects by default.

### CarbonHotkey use-after-free window
`CarbonHotkey.swift:69` — `Unmanaged.passUnretained(self).toOpaque()` has a window between `InstallEventHandler` returning and the first event where deallocation would free the memory the callback reads. A `passRetained` + release in the handler would eliminate it.

### Hotkey re-registration can spuriously fail on the same chord
`AppDelegate.registerSummonHotkey` builds a new `CarbonHotkey` while the old one still holds the registration (`AppDelegate.swift:264`). Re-registering the held chord risks `eventHotKeyExistsErr`, leaving the failure flag set though the old registration works. Nil-out (unregister) first, or reuse one instance. Related: first-launch conflict leaves the app hotkey-less (fallback is `.default` itself — a no-op); try an automatic alternative. Surface `eventHotKeyExistsErr` distinctly for a "taken by another app" message. No "disable hotkey" option exists (recorder offers Esc-cancel and ⌫-reset only).

### Persisted hotkeys bypass recorder validation
The recorder rejects bare and Shift-only chords, but `Preferences.loadSummonHotkey` accepts any nonzero modifier mask. Corrupt or hand-edited defaults can therefore register Shift+letter globally. Share one validator across recording, defaults loading, and Carbon registration; reject unknown modifier bits and invalid key codes.

### FileSearchSession.onStart can miss after cancel
`FileSearchSession.swift:84-91` — The debounce hop to main can queue after `finish()` already ran. The `isPending` guard catches this, but `onStart` never fires, silently missing the `fileRunsStarted` counter.

### PanelModel missing @MainActor
`PanelModel.swift:58` — The class lacks `@MainActor` despite the doc comment saying "every member is main-queue confined." The compiler cannot enforce confinement at compile time.

### CommandStore onChange is single-subscriber
`CommandStore.swift:31` — If two consumers both assign `onChange`, the second silently overwrites the first. A multi-subscriber notification would be more robust.

### CommandStore watch budget excludes directories
`CommandStore.swift:150-151` watches every root + command dir unconditionally; only nested files go through `watchBudget` (`:163-170`). N commands = N+ fds regardless of `maxWatchTargets`. The "store-wide budget" comment (`:119-121`) is false for the directory layer.

### Watcher rebuild thrashes on order-only changes
`CommandStore.swift:195` compares `[URL]` with `!=` (order-sensitive) but `contentsOfDirectory` order is undefined. Same set, different order → close + reopen every fd. Compare as sets.

### Nondeterministic watch coverage under pressure
`CommandStore.swift:232-251` fills the per-command share from directory order; under a tight budget whether `main.js` or a vendored file gets watched is arbitrary. Prioritize the entry file.

### Duplicate command names across roots resolve arbitrarily
`Command.swift:14-16` admits two roots can hold the same name; `command(named:):76-78` returns the first after title sort. The Maker saves to the primary root, but a same-named secondary-root command can shadow it. Add duplicate detection / `ScanError`.

### Partial-save window observable by the watcher
`CommandWriter.swift:130-148` writes extras first, manifest last as "commit point". A concurrent rescan (0.3 s debounce) can load old-manifest + new-files mid-save. Stage + rename, not just per-file atomicity.

### Failed-save rollback loses overwritten helpers
`CommandWriter.swift:184-217` snapshots only manifest + entry; `rollback:230-252` restores only those. An overwritten `lib/util.js` is gone (comment `:226-229` admits it). Snapshot everything or stage first.

### Error-only scan changes are invisible
`CommandStore.swift:191,198-201` fires `onChange` only when `commands != _commands`. Breaking a manifest (new `ScanError`, same list) notifies nobody; `CommandSource.onReload` never fires and no `scanErrors` UI exists. Add the surface.

### JSRuntime describeReason can clobber the reported exception
`JSRuntime.swift:137-139` captures into `exceptionValue`; `describeReason:239-254` runs `evaluateScript` on the same context without swapping the handler. A throwing `toJSON`/Proxy overwrites the original. Swap/clear the handler while rendering.

### Overwritable `__invoque_*` globals
`JSRuntime.swift:211-214,259-265`, `InvoqueBridge.swift:293` install `__invoque_*` as plain globals; reassignment turns a clean run into timeout/void with a misleading error. Define as non-writable.

### Stuck-command ban is too broad, has no reset
`JSRuntime.swift:34,62-66,83` bans by slug — collides across roots and with Maker staging dirs. One hang disables all same-named commands for the session; only relaunch clears. Key by directory, add UI to clear. The ban is also invisible to the user: a stuck command silently stops answering, so surface it (HUD or a status affordance) rather than leaving users to guess why a command went quiet (`swe.md` C1).

### Validator accepts non-callable default export; runtime rejects it
`GeneratedCommandValidator.swift:140` treats any `export default` as an entry point; `JSRuntime.swift:291-296` only rewrites callable shapes. `export default {title:"x"}` / `42` / `class…` look clean, then throw. Align the two (incl. class check — `typeof run === 'function'` is true for classes).

### Fenced/duplicate extras last-win silently; numeric names become junk files
`GenerationParser.swift:199-207,256-261` flags duplicate manifest/entry but silently overwrites repeated extra filenames. `headerNamePattern` accepts `--- 1 ---`, and the writer persists a file named `1`. Flag duplicates; reject prose/numeric names.

### Filter triggers with spaces or case mismatch are dead
`CommandSource.swift:44,87` uses `keywords.first` verbatim; `PanelModel.swift:460-475` splits on the first space, `==` case-sensitive. A keyword containing a space can never route (even the pinned-row path requires first-token equality); `JSON` never triggers `json`. Validate manifests (reject spaced keywords) and match case-insensitively.

### LLMClient truncation discards the limit; Anthropic probe assumes OpenAI shape
`LLMClient.swift:204-206` throws `truncatedOutput(limit: 0)` on `finish_reason == "length"` (Anthropic path passes `max_tokens` correctly). `testConnection:176-180` reads `data[].count`, reports "OK" with no model count, never checks the configured model exists.

### Maker stage() races reset() cleanup
`MakerModel.swift:274-299` stages to temp; `reset():348-351` deletes it. `discard()` mid-run deletes the dir from under the in-flight `JSRuntime` read → "could not read entry file". Epoch-guard the cleanup or stage per-run.

### SearchModel pinned-band cap wastes a slot
`SearchModel.swift:164`: `bandCap = maxResults - path - calc - web - 1` always reserves 1 row. Pins-only query yields 49 rows, not 50. Only reserve when unpinned matches exist.

### File-search caps truncate before ranking
`FileSearch.swift:229,232`: `maxMatches = 500` stops the walk in enumeration order, then ranks only those 500 — an exact filename late in the walk is never considered. Same for `maxVisited = 500_000`. Pin partition happens after truncation, so a pinned file past the cap is still lost despite the comment. Rank-then-truncate (or shallow-first emit + extension filtering, §Performance).

### Sparse file-search matches can remain buffered until completion
The timed flush is checked only when another match arrives. One useful early match followed by a long no-match walk remains in `pending` while the UI says "Searching files…". Check the interval on a visited-entry/time stride independent of matches, or drive emission through an async timer/channel. Add a fixture with one early match and a deliberately long unmatched tail.

### File search misses prune entries; no symlink-loop guard
`skippedDirectoryNames` is only `node_modules/pods/venv` (`FileSearch.swift:140`). Missing `__pycache__`, `.venv`, `DerivedData`, `Library/Caches`, `.Trash`, Time Machine `Backups.backupdb` (walking an external backup drive fully is a hang). `.git` relies on `isHiddenKey` for dot-dirs on all volumes — verify. No symlink-loop guard beyond `maxVisited`; a cyclic tree burns the full budget every keystroke.

### File search symlink dedupe is incomplete; id/display path forms mismatch
`seenPaths` uses `standardizedFileURL` (no symlink resolution); `AppCatalog` uses `resolvingSymlinksInPath`. `/tmp` → `/private/tmp` aliases double-list; overlapping home+system skips rely on exact string equality, so a symlinked home double-walks. ID uses `standardizedFileURL.path` while subtitle/action URLs use raw `.path` (`FileSearch.swift:466,478`; same in `PathSource`) — `..` segments reach display/actions.

### AppCatalog indexes only four directories
`AppCatalog.swift:32`: `~/Downloads`, `~/Tools`, `/opt`, DMGs, deep Setapp subtrees invisible. No Spotlight fallback, no user-added folders. ~~No file watcher~~ — landed (PR #50: `DirectoryWatcher` rescans on filesystem events, retries failed opens on a cooldown, scans on a dedicated serial queue). Duplicate `matchText` when name == fileName (`AppSource.swift:97`, e.g. `Safari Safari`) inflates the length penalty. No app keywords (`browser` → Safari). `resolve` trims `.whitespaces` but not newlines (`AppCatalog.swift:65`).

### Path source: plugin types treated safe; no completion; raw action URL
Blocklist misses loadable plugin types (`.bundle/.kext/.appex/.mdimporter/.qlgenerator` — not `APPL` packages, treated safe-to-open). No path completion (`/us` → nothing). Action URL not standardized (`..` reaches `NSWorkspace`).

### Esc on consent/maker nukes context
`LauncherPanel.swift:59-61` → `PanelController.hide()`. First Esc with `permissionRequest`/`makerIsActive` should dismiss the card, second hide. Currently loses the prompt. (Also `glm.md` B2: the footer's "esc dismiss" hint promises card-dismiss semantics the behavior doesn't deliver — pick one and align copy or behavior; PLAN §3's promised ⇧⏎ secondary action is likewise still absent — B3.)

### Maker inline fields can trap keyboard focus (`glm.md` B5 — needs macOS verification)
`InlineField` (MakerView) takes first responder on click; arrow keys then edit the field and there is no keyboard path back to the search field (Tab order across the SwiftUI/AppKit mix is undefined). Field-Esc (or reverse-Tab) should return focus to the search field before hiding the panel.

### `search` keyword silently reroutes web queries (`glm.md` B8 — decision)
`search foo` enters *file* mode while every other mental model says "web search". Deliberate (README says so) but bug-report bait. Consider `fs`/`files` as a fourth alias and keeping `search` for the web fallback, or at least keep calling it out in release notes.

### Partial theme import drops the typeface via Jetty lens
`AppearancePreset.swift:227-229,243-308`: file with material/tint but no label/highlight routes to `JettyTheme` (no typeface field) → silent font reset. Preserve the current typeface on partial imports.

### HUD/Panel windowing papercuts
`NSApp.currentEvent` for ⌘⏎ is fragile (`PanelView.swift:501-503` — nil/stale event misclassifies Allow vs neutral). `contextMenu` in a never-main `.nonactivatingPanel` may fail or steal key status and trigger `didResignKey` hide. `headerRowHeight = 54` drives `ballDiameter()` but drifts from the real header metrics. `LauncherPanel` never sets `hasShadow` (square-window shadow risk with the 12pt inset). Preview rows use hard-coded `/System/…/Finder.app` paths that may not exist. `PanelController.show()` doesn't re-check presentation appropriateness — during a modal alert the summoned panel could overlap it (`swe.md` C9; low risk). (`glm.md` B7: `HUD.dismiss`'s animation completion can lag seconds when the app is background-throttled — a toast outlives its timer; cosmetic.)

### AppKit work from command queues needs a thread-affinity audit
Clipboard, workspace open/activate, Accessibility prompting, and System Settings calls are reachable from JavaScript worker queues. Classify each bridge call: UI and activation APIs should hop to `MainActor`; disk, network, and process work must remain off-main. Avoid synchronous main hops from JS callbacks. This is an investigation item until Thread Sanitizer/runtime proof identifies a concrete violation.

### Shared ISO8601DateFormatter across threads
`GitHubRelease.swift:12` decodes off-main via `URLSession`. Lock it or construct per decode (negligible cost at once-a-day frequency).

---

## Performance Improvements

### FileSearch.resourceValues per entry
`FileSearch.swift:418-434` — Every visited file triggers `resourceValues(forKeys:)`. For ~100K files, this adds up. Consider batch-fetching or caching. (Muse: also `standardizedFileURL` per directory, `file:` id string + `isExcluded` closure per directory — snapshot the exclusion set once per scan instead of dispatching per directory — up to 12 `fileExists` probes per `build`-named dir in `hasProjectManifest:455` — cache per parent — `homeDirectoryForCurrentUser` per match `:479` — hoist — volume resolution per scan `:112` — cache, refresh on mount notes.)

### FileSearch.sorted array rebuilt on every flush
`FileSearch.swift:334-336` — `boosted.sort(by:)` and `rest.sort(by:)` re-sort entire accumulated arrays on every flush (per 48-match/0.12 s emission, ~10 flushes). Single end-sort or a top-50 heap is cheaper; per-flush snapshots also rebuild 50 `Item`s with `Bundle` reads for `.app` hits.

### Fix ranking integrity first, then speed (caps truncate before ranking)
See Bugs: rank-then-truncate, or shallow-first BFS emit + exact-basename fast path + query-extension filtering (`repo` filters `rep` results synchronously for instant paint while the rewalk runs) + visited-count progress. Consider an FSEvents-invalidated filename index (the Alfred/Raycast architecture) with the live walk as fallback.

### InvoqueBridge.storage.get reads full JSON every call
`InvoqueBridge.swift:136-141` — Every `invoque.storage.get()` deserializes the entire `storage.json` (full-file write on set/delete). A chatty script parses + serializes per key. Cache with dirty flag + size cap before it becomes a disk-abuse vector.

### SearchModel allocates per keystroke
`SearchModel.swift:105-182` — Every keystroke builds new arrays and dictionaries (`bestByID` + `ScoredItem` per match + full sort + two pin-band filter passes). Snapshot pin/block sets once per query (closures may lock per call today); `Frecency.score` locks per item (`:84`), `save()` JSON-encodes 500 entries while holding the lock (`:71`). `topHits()` iterates every source's full item list on each empty query (every summon, every cleared field) — a cached eligible-items list would cut the per-summon allocation (`swe.md` C4). A pre-allocated scratch buffer would help at scale.

### FuzzyMatcher lowercased copies per candidate
`FuzzyMatcher.swift:87-92` — `query.lowercased()` and `candidate.lowercased()` are called for every candidate. Lowercase the query once per keystroke and share across `match` + `contains` (`:162` reallocates per item); case-folded substring prefilter before the full scorer at walk scale; locale-invariant + diacritic folding (`cafe` vs `café` misses today; Turkish-`I` locale risk); greedy alignment without backward refinement (fzf does one); no out-of-order word matching (`screen lock` vs `Lock Screen`).

### Icons resolve synchronously on main per row per body (biggest UI jank)
`PanelView.swift:181-184,263` + `DetachedSearchView.swift:68-72,112` call `NSWorkspace.icon(forFile:)` on main for every visible row on every keystroke *and* selection change. A bounded sync `NSCache` landed (PR #51) — the remaining work is the async pipeline: async cache by path (mtime-aware) + placeholder glyph. Same for `AdaptiveAccent` first-sample on main (`tiffRepresentation` + `CIAreaAverage` per new icon on arrow-key navigation — prefetch off-main, bound the cache with LRU, currently unbounded over file-search paths).

### Filter mode redoes everything per keystroke, no cache/cancel
`JSRuntime.run:96-101` + `execute:112-125`: fresh queue + `JSContext` + entry read + decode + timer per run; `scheduleFilter` cancels the debounce but not the in-flight run — fast typing stacks concurrent contexts. Cache entry source by mtime; coalesce/cancel overlapping runs per command. `CommandSource` rebuilds every `Item` (incl. `matchText` joins) per keystroke — cache, invalidate on `onChange`. `apps.list()` is a full disk scan per JS call with no cache.

### Main-actor disk I/O in the Maker; grants re-hash per run
`MakerModel.test:231-233` (stage + load + hash) and `save:325` (rescan + locale-aware title sort) run on `@MainActor` — move off. Grants re-hash the entry file per risky run (`Data(contentsOf:)` + SHA-256, then runtime reads it again) — cache by mtime. `PipeDrain` busy-polls (`:599-608`, 10 ms loop up to 5 s) — use a semaphore/group.

### SwiftUI micro-costs
`.animation` on the whole `ScrollView` (`PanelView.swift:304-306`) animates all descendants incl. the `scrollTo` side-effect. `.interpolation(.high)` per icon per frame (`.low` or pre-scaled cache suffices at 28pt). `updateNSView` rebuilds `nsFont(size:22)` per body. `VisualEffectBlur` resets material/blend/state even unchanged. Settings preview re-resolves icons on slider drag. CRT redraws ~147 scanline fills + gradient per selection (`CRTScreenOverlay.swift:15-24` — static layer / `drawingGroup` / cache). Boing first smooth-ball render (trig per pixel) stalls 10–20 ms on first Amiga summon.

---

## Code Quality

### PanelModel is a 932-line god object
`PanelModel.swift` owns query state, results, selection, filter mode, file-search mode, entry rules, maker routing, command results, and stability merges. Extract filter-mode logic and file-search orchestration into separate types.

### InvoqueBridge is a 638-line monolith
`InvoqueBridge.swift` has every JS module as private static functions. Each could be its own type for independent testability.

### JSRuntime.opaqueRanges is fragile
`JSRuntime.swift:311-379` — The scanner has known gaps: regex with `${}` nesting inside templates, regex flags, and nested template literals.

### Preferences init is 70+ lines of defaults loading
`Preferences.swift:398-470` — A property-wrapper pattern or `DefaultsSchema` struct would reduce boilerplate.

### Slot math duplicated between ranker and stability merge (`glm.md` S2)
`SearchModel.results`' `bandCap`/`rankedSlots` and `PanelModel.stabilizedRankedRows`' `middleSlots` are copy-paste variants of the same reservation arithmetic, and the stability merge reimplements the ranking keys — including a Dictionary + Set allocation and a second `FuzzyMatcher.match` per row per keystroke, bounded at 50 (`swe.md` C11). One shared `rankedSlots(pins:web:)` helper prevents drift next time a head-pin namespace is added (`url:` already had to be threaded through by hand — PR #31).

### No view-level tests at all (`glm.md` S3)
Logic coverage is strong, but `PanelView`/`ResultRowView`/`MakerView` layout regressions (the kind PR #43's lost title-color bug was) are invisible to CI. A few snapshot or frame-invariant tests on macOS runners would catch visual drift cheaply.

### Correctness papercuts (schema, validation, Maker UX)
- Bare-string/array JS returns silently become `.void` (`JSRuntime.swift:439-451`); title-less items dropped via `compactMap` with no log (`:455-462`). Report shape mismatches in result/HUD instead of dismissing; flag in the validator.
- `arguments` binds from the query now (`keyword <rest>` → `args[0]` — PR #67), but no args *form* exists: Maker test args don't match production, and there's no manifest-driven input UI. Render an args form (see Missing Features) or document the query contract in the Maker.
- Unknown `runtime` yields generic `DecodingError` (`:107`); produce actionable `ValidationError`, with an explicit "exec unsupported yet" message.
- No validation for empty `title`, empty/whitespace `keywords`, duplicate permissions, unknown icon symbol names — all fail downstream as blank rows / dead triggers / missing icons.
- Manifest `entry` → `command.json` caught only at save (`CommandWriter.swift:119-122`); validator's presence check always passes for it. Check explicitly.
- Extra `.js` files are a validator hard-error but the system prompt invites extras (`SystemPrompt.swift:27-30` vs validator `:54-62`). Forbid `.js` extras in the prompt outright.
- Permission scan misses indirection (safe-direction only): `(invoque).fetch()`, `globalThis.invoque.fetch`, `invoque["fetch"]` missed (`:285-292`); only `=`/`return`/destructure flagged. Runtime `TypeError` points nowhere near permissions — extend the scan or the error.
- `notification` permission is incoherent: `notify` always available (`InvoqueBridge.swift:99-105`) so under-declaration never flagged, while declaring `notification` without calling `notify` is flagged unused. Pick one meaning.
- System prompt promises user-visible `notify` (`SystemPrompt.swift:70`) but the bridge sinks to log. Fix the copy until `UNUserNotificationCenter` lands.
- Shell-safety rules are prompt-only (`rm -rf`, `curl|sh`, exfiltration, unquoted interpolation) — nothing scans shell strings. Add a destructive-shell lint requiring explicit override.
- `MakerView.parseArgs` has no escapes (`:329-352`, backslash literal). Document or implement quoting.
- Test log shows `logs.suffix(6)` only — earlier lines (often the actual error) unreachable in-panel. Add "view all".
- Filter UX: case-sensitive single-token triggers vs case-insensitive search everywhere; bare keyword stays a normal search (discoverability rests on one row pick); permission badges render duplicates verbatim; draft consent row names an uninstalled command (ambiguous vs installed same-name); `displayedPrompt` freezes while the query edits; no "running…" state for long action runs; stuck-disabled message offers no path back except relaunch. A failed filter run's error row only offers copy-text — no "reveal command folder" or "view log" affordance for debugging (`swe.md` U8).

### Ranking notes (documented behavior worth revisiting)
Frecency is global per id (never per-query — `s` → Safari vs Slack can't learn); `file:` ids never train frecency; frecency can never beat title length (length sorts before boost), so a 20-visit long name loses to a never-used short prefix forever. `matchedInTitle` does useless work for fuzzy-tier rows (impossible by definition — early-out).

---

## Security hardening

Concentrated risk is the bridge (JSC gives no ambient authority). In priority order:

1. Filter-mode allowlist too narrow: `filterWithheld` strips only `{shell,paste,apps}` — per-keystroke filters keep `network` + `clipboard.read` + `files` (write to `data/`) + `open` (new tab per keystroke). Clipboard → `fetch` exfiltration needs no action beyond typing. Withhold/rate-gate `open`/`network` in filter mode; warn on `clipboard.read` + `network` combined.
2. `open`/`network` + `clipboard.read` need no first-run consent (`risky = {shell,paste}` only) despite `open` being acknowledged egress. Consent on first network/open use, or when combined with `clipboard.read` (PLAN §4.3 already defers this decision — decide it).
3. Shell processes survive timeout: `installShell:368-409` blocks in `waitUntilExit()` with no deadline; `JSRuntime` timeout abandons the thread but never kills the `Process`. Kill the process group on timeout; cap output.
4. Unbounded outputs: shell stdout/stderr, ~~fetch bodies~~ (capped at 20 MB — PR #57, enforced at the read), entry files (`:120`), `storage.json` — a `yes`, runaway log, or oversized entry still OOMs the launcher. Extend the fetch pattern: byte caps with truncation errors + honest UI ("body truncated at N MB").
5. Source/consent and filesystem TOCTOU: consent hashes the entry, then `JSRuntime` rereads it later; bytes can change between approval and execution. Snapshot source plus digest at dispatch and execute that immutable snapshot, including every executable helper. Separately, entry/`fs` validation resolves symlinks before later path use (`resolve:317-325`); use no-follow/open-relative mechanics where practical.
6. HTTPS→HTTP redirect keeps custom headers (`HTTPRedirectGuard:563-571`). Strip sensitive headers or block downgrades.
7. Arbitrary `fetch` methods/headers (`:244-258`): any method, bodies on any method, `Host`/`Cookie`/`Content-Length` allowed. Constrain methods, forbid framing headers.
8. `NSPasteboard` touched from the JS queue (`:202-215`, `:437-439`); `paste` intentionally leaves text on the clipboard (`:469-470`) but consent copy (`consentLine:92-100`) mentions only keystroke simulation. Document both.
9. Grants live in UserDefaults (forgeable by any user-context process, documented) — making records tamper-evident (HMAC, Keychain key) is the recorded follow-up alongside auxiliary-file hashing.

---

## Release and supply-chain work

### Sign and notarize public builds
The release workflow ad-hoc signs and tells users to bypass Gatekeeper, contrary to the documented Developer ID plan. A public stable build must use Developer ID Application signing, hardened runtime, notarization, stapling, and verification from a quarantined clean account. Document secret rotation; never make recursive quarantine removal the normal install path.

### Make signature identity the updater trust anchor
`SHA256SUMS.txt` from the same release channel detects corruption, not compromise. Before replacement, require the expected Developer ID team, bundle ID, and a strictly newer version after extraction or mounting. Prefer Sparkle with EdDSA-signed appcasts over extending a bespoke installer; preserve rollback and fail closed.

### Pin PictKit reproducibly
The Xcode package reference tracks Pict's mutable `main` branch and no `Package.resolved` is committed. Pin a reviewed tag or exact revision, commit resolution state, and update deliberately through CI.

### Gate releases on CI for the exact tagged SHA
The release job checks only that the tag is reachable from `main`; a failing or still-running revision can publish. Require a successful required workflow for the exact SHA, or rerun the complete build, tests, and icon gates before packaging.

### Benchmark and document the enabled JavaScriptCore JIT path
The `com.apple.security.cs.allow-jit` entitlement landed on main in `c749e13`, resolving the PLAN/configuration mismatch. Still benchmark filter/action latency under hardened release signing and document why the broader runtime capability is justified.

---

## Missing Features (per PLAN.md)

### notify is a log sink
`InvoqueBridge.swift:99-104` — `invoque.notify()` just logs. Needs `UNUserNotificationCenter` wiring. (The system prompt already promises user-visible notifications — fix the copy in the meantime.)

### exec runtime not implemented
`CommandManifest.swift:37-39` — `Runtime` only has `.js`. PLAN says `exec` is "designed-for but post-v1."

### view mode deferred
PLAN line 274: "deferred. Decision recorded."

### Clipboard read + network exfiltration gap
PLAN lines 336-344 — A command with `clipboard.read` + `network` permissions can silently exfiltrate clipboard contents. (See Security hardening for the concrete gates.)

### ~~No "Commands folder" menu item~~
Landed — PR #63 (status menu item + the Commands settings tab it complements).

### Launcher parity (highest impact first)
- ~~Learned empty state~~ — ✅ PR #27 (frecency top hits, capped at 9). A follow-up could add recent `find` opens in their own namespace.
- Per-query frecency (`s` → Safari vs Slack depending on past `s`-queries) — single biggest ranking upgrade.
- ~~Matched-letter highlighting~~ — ✅ PR #43 (semibold contiguous occurrence; a colored-variant or fuzzy-span refinement remains optional).
- ⌘1–9 quick pick, Tab autocomplete, ⌃N/⌃P, ⇧ actions panel, Space QuickLook, ⌘L large-type, `?` help row.
- Secondary actions per row (`Item.Action` lacks them): copy-path / open-with / show-in-Finder / uninstall; file drill-in (enter folder to navigate); drag-out of files. (⌘C copy landed — PR #40.)
- File mode: content search, preview, extension filters, recency/size sort, recent-files source, custom scope folders, Time Machine exclusion, editable query + sort toggle in the detached window (currently read-only header).
- Apps: user-added watch folders, keywords/categories, Spotlight fallback.
- Web: suggestions API, multi-engine prefixes (`g`/`yt`/`gh`), history, custom engine URL; named quicklinks with placeholders and selected-text input.
- Onboarding: explain the summon hotkey, status menu, command folder, Maker key setup, generated-code trust model, and lazy Accessibility prompts without forcing permissions at launch.
- Path completion (`/usr/lo` → `/usr/local`); `path:` row as navigator (nearest existing parent + suffix as second row).
- Calculator: `%`, `^`/`pow`, constants, factorial, unit/currency (`100 usd to eur`, `32f to c` reuses the pin-first row + copy); a "⏎ copies" hint on the answer row to teach the shortcut (`swe.md` U10). (Hex/binary/octal conversion landed — PR #47.)
- Offline dictionary: `define serendipity` via `DCSCopyTextDefinition` — public API, no permission, no network (`glm.md` F12).
- Multi-type pasteboard: pasting an image into the panel → temp file → `path:` row (Raycast does this; `glm.md` U1).
- `invoque://` URL scheme — `invoque://search?q=…` (or command invocation), so external apps and scripts can drive the launcher (`swe.md` F15).
- Emoji / symbol source: `emoji fire` → 🔥 — a pure data-file keyword source (distinct from the developer-facing SF Symbols browser below) (`swe.md` F18).
- System: log out, screen saver, dark-mode/wifi/bluetooth toggles, restart Finder, force-quit window, remind-me/timer built-ins (`swe.md` F20). Empty Trash covers `~/.Trash` only; failures now HUD instead of logging silently (PR #55), and PR #61 adds trusted confirmation plus honest home-Trash copy — all-volume Finder semantics remain open.
- Clipboard history / snippets / window switching (history landed — PR #39).
- Hotkey: double-tap-modifier (needs event tap + AX — PLAN defers), multi-chord sequences.
- Updates: progress UI, cancellation/resume, markdown release notes (raw body today), delta/auto-install/relaunch (Sparkle-class), download integrity beyond TLS+quarantine (document the gap at minimum), rate-limit messaging (`Retry-After`).

### Maker gaps
Streaming progress and an elapsed-time display during generation (a Cancel button landed — PR #60 — but the 300 s wait is still silent, `LLMClient.generationBudget:122-124`); model list; temperature/token controls; token/cost estimate + transcript budget meter (full transcript resent every round); measured test duration vs the ~80 ms filter budget + filter-budget lint; manual fix without regeneration (editable panes + revalidate); diff view on update; restore-from-`history/` button + prune policy (`history/` grows unbounded, snapshots only manifest+entry, restore is manual copy); `edit command <name>` (landed — PR #42); `revert to revision N`; loading state for long action runs; recovery UI for stuck-disabled commands; provider presets (Ollama/LM Studio/OpenAI/Anthropic one-click — keyless-local already works, undiscoverable); args form from the manifest (un-deads `arguments`, makes Maker test args match production); permission preview/dry-run UI (modules touched, covering permissions, first-run-gated set); trigger-collision detector at scan time (shared keyword, or keyword == another command's name); per-command timeout; fetch/shell/output/log size caps; `scanErrors` surface; duplicate-name/keyword warnings; per-command enable/disable. (`glm.md` U4: typing `make …` with no API key configured goes straight to a transport failure — the idle MakerView should detect "no key stored" and link to Settings → AI. `glm.md` U5: an action-mode failure surfaces as one 1.6 s HUD line — long errors are unreadable and uncopyable; offer Copy-error or a result row instead. `glm.md` S4: `CommandLog` flattens log levels to strings, so the Maker's "last 6 lines" can't prioritize `console.error`.)

### Settings gaps
Search; keyboard-shortcut reference pane (panel verbs ⏎/⌘⏎/⌘P/⌘B/⌘C/Esc undiscoverable); per-command hotkeys; fallback-action editor; Universal Actions / selected-text pipeline; light/dark auto theme variant (single hex blinds in the opposite appearance); row density / icon size / font-size controls; divider + footer visibility toggles; focus-ring tint; side-by-side light/dark preview with preset thumbnails; storage usage per command; import/export of the whole settings bundle (`swe.md` T8). (`glm.md` F4: PLAN §7's **Commands** pane landed read-only — PR #63 lists loaded commands with mode/permission badges, consent state, `scanErrors`, roots, and a menu item; still missing: per-command enable/disable, grant **revocation** for `shell`/`paste` consents (`swe.md` C5 — grants are irrevocable today), and the **Permissions** pane (Accessibility status for `paste` + deep links). `glm.md` U3: the Pinned & Blocked lists need in-list search once they grow; `swe.md` U5: they also show raw ids like `app:com.foo.bar` — strip the namespace prefix for readability.)

---

## UI/UX Improvements

### No settings for font size / panel size
`Preferences.swift` — The typeface is configurable but not the size. No user-configurable panel dimensions or placement: the 25%-down anchor is hardcoded in `PanelGeometry` (a vertical-offset slider or drag-to-position is the natural Appearance addition, `swe.md` V2). (Panel is fixed 680×440 and never collapses — empty query, 1 result, permission card all show the same tall void. Collapse to content with a cap, Alfred/Raycast-style.)

### "Searching files..." has no progress indicator
`PanelView.swift:245-246` — A spinner or progress bar would give better feedback during file scans. (Panel footer only says "Searching…"; detached header has `ProgressView`, panel has none; filter 80 ms debounce has no affordance at all.)

### No empty-state illustration
When the panel first opens with no query and no top hits, it shows plain text. A small illustration would make first-run warmer.

### The Maker view feels utilitarian
The Maker is functional but visually plain. Progress indicators, draft previews with syntax highlighting, and a more polished feedback loop would make command generation feel more like a creative tool. (Maker confetti stripe-burst on save + new row pulsing once would sell the moment.)

### Mouse click conflates selection and execution
A single click executes a result immediately. That is fast but unforgiving, especially before PR #61 intercepts consequential system rows. Consider single-click select plus double-click/Return execute, or retain one-click only for explicitly safe actions. Test focus, selection, context menus, and nonactivating-panel behavior before changing the global contract.

### Hand-tune small app and status icons
The Memphis app artwork is distinctive at large sizes, but its wordmark, stripes, grain, and confetti collapse at 16–32 px. Supply dedicated small variants built around the cyan center mark and two or three flat colors. Evaluate an optional monochrome template status icon against light/dark menu bars.

### Selection behavior knobs
No hover-to-select — mousing over rows doesn't move the selection the way Spotlight does; one `onHover` + select (`swe.md` U2, subjective). `moveSelection` wraps at both ends — Alfred/Raycast don't wrap; Spotlight does, so wrap is defensible but a no-wrap option or preference is worth considering (`swe.md` U7).

### Panel layout papercuts
Dividers draw above/below the consent/maker cards, doubling their padding lines (`PanelView.swift:41,58`). ~~Footer is one centered string~~ — split into status/hint clusters with a live result count (PR #65); remaining footer nits: long hints still truncate as one unit and only a few chords are context-filtered. Placeholder hardcodes `"Search"` — never contextual (`find` / filter / `make`); no localization anywhere. No selection slide (fill crossfades but never glides — `matchedGeometryEffect` pill). Glow shadow (radius 10, opacity .5 on 6pt spacing) bleeds on light themes. No hairline stroke / inner highlight — glass washes out over busy wallpaper (Raycast-style hairline missing). No focus ring (`focusRingType=.none`). Symbol-vs-bitmap optical mismatch (`.title3` vectors in a 28pt bitmap column). Status icon is full-color in a monochrome menu bar (consider `isTemplate` variant). Detached window ignores theme text (`.primary/.secondary` always, even for solid/gradient `labelHex` themes). (`glm.md` V6: MakerView's system `Button`s/`ProgressView`s keep system styling — on a dark Synthwave `solid` fill with a light label they clash; a tint/label-color pass would keep the card coherent. `glm.md` V7: the pinned-row `pin.fill` at 65 % opacity trailing the row is easy to miss — leading-position badge or stronger treatment.)

### Accessibility gaps (also speed)
Custom list has no listbox semantics (rows `.isButton/.isSelected`, no container role — VO may not announce arrow-key moves). Permission Allow unreachable by Tab (focus pinned in search field; ⌘⏎ only). AngleDial gesture-only (needs `.focusable()` + arrows; 46pt minimum). HUD silent to VO (no `NSAccessibility.announce`, no sound). HUD fade ignores Reduce Motion. CRT hurts contrast with no auto-gate (Increase Contrast / low vision). Increase Contrast / Differentiate Without Color unhandled (no border boost; 0.75-opacity subtitles over mid-luma fills likely fail WCAG). Dynamic Type overflows the fixed panel (`lineLimit(1)` truncation). No in-app shortcut reference.

### Highest-leverage UX fixes (each small, each felt every summon)
Collapse to content; async icon pipeline; matched-substring bold + frecency ember; contextual placeholder + footer with count + applicable chords only; keyboard parity (⌘1–9, Tab-complete, ⌃N/⌃P, QuickLook, ⌘L, `?`); per-query frecency + learned empty state; instant-feeling file mode (BFS shallow-first + extension filtering + progress + editable detached query); command runs with progress + honest truncation affordances; consent that teaches (permission preview + destructive-shell lint); accessibility as speed (listbox semantics, announced HUD, focus paths, motion/transparency/contrast honored, shortcut reference).

---

## Theming

- Hairline stroke + inner top highlight on glass/solid; saturation boost under translucency.
- Dual-appearance hexes (light/dark tint/gradient/label) or dynamic provider.
- Selection text override + contrast-floor check for 0.75-opacity subtitles.
- Row density / icon size / font-size; divider + footer toggles; focus-ring tint; side-by-side light/dark preview with preset thumbnails.
- Show inert tint controls disabled-with-reason on liquidGlass/glassClear instead of hiding.
- Cap adaptive-accent saturation/brightness for grayscale icons (Terminal black → gray wash); offer glow-only vs fill mode.
- Detached window inherits the full theme, not just shape.
- Time-aware theme: dawn/day/dusk/night gradient interpolating angle + tint (opt-in); scheduled presets are the simpler variant — Synthwave by night, Memphis by day (`swe.md` T2).
- Accent follows wallpaper — sample `NSWorkspace.desktopImageURL` for the tint (`swe.md` T3).
- Seasonal built-in theme (snow/Halloween decoration style) — `PanelDecoration` already supports pluggable styles (`swe.md` D7).
- CRT scanlines cross the one line users actively read (`glm.md` V8) — at high intensity consider clipping the overlay below the header, or offering the choice.

---

## Creative Ideas

### Typing sound effects
Optional click/tap sound on each keystroke (like a mechanical keyboard). Volume and pitch could be themeable. (Muse: soft tick on move / thunk on open instead — off by default, Keychain-free pref. Either way: subtle, optional, off by default.)

### Result row hover glow
Subtle glow or scale-up animation on mouse hover. The panel already tracks selection; adding a hover state would make it feel more alive. (Muse: match glow — bold matched substrings in highlight color; frecency embers — recent picks get a subtle warm edge.) — *Hover fill landed (PR #46, 45 % of selection opacity, no animation); the glow/ember variants remain.*

### Typing speed adaptive UI
If the user types fast, reduce animation intensity. If they type slowly, allow more visual flourish.

### Recent history sidebar
⌘R or right-arrow expansion showing the last 10-20 actions with timestamps and the ability to re-run or pin.

### Theme marketplace (local)
A folder of `.json` theme files browsed like a gallery with live preview on hover. Not remote — just a local directory. A "share this theme" export could bundle the preset plus a rendered preview screenshot straight from the Appearance preview (`swe.md` V7). (`glm.md` D5 variant: a `make me pretty`-style easter egg that mints one random harmonious palette — HSL rotation — as a one-off preset.)

### `invoque` easter egg (`swe.md` D2)
Typing `invoque` surfaces a credits card — bouncing boing ball, version, small signature. Zero-cost whimsy that rewards curiosity about the app's own name.

### "Time saved" stat (`swe.md` D3)
Count launches quietly and show "Invoque has launched N apps for you" in Settings → General — a tiny pride metric.

### Query ghosts (`swe.md` D4)
Fish-style autosuggest: a faint inline completion in the field offering the top hit's title; Tab accepts (pairs with the Tab-autocomplete parity item). Needs care so the ghost never reads as typed text.

### SF Symbols browser (`glm.md` D3)
`sym star` → rows rendering the symbols themselves, ⏎ copies the name, ⌘⏎ copies the `Image(systemName:)` snippet. Developer-delightful, pure in-memory data, fits the keyboard-first ethos.

### Tip of the day (`glm.md` D8)
The empty panel (now the top-hits rail, PR #27) could occasionally surface an unused built-in ("did you know: `find ` walks the disk without Spotlight?") as a subtle footer line — capped frequency so it never nags.

### Smart aliases
Auto-learning: if the user frequently types "par" and picks "Parallels Desktop", suggest "par" as a pin. (This is per-query frecency wearing a trench coat — implement the ranking first.)

### Multi-monitor panel positioning
Remember which display the panel was last shown on and default to it.

### Window management commands
Built-in system actions for window snapping (left half, right half, maximize, center).

### Custom result row templates
Allow users to define custom row layouts — show the command's last-run time, or a subtitle with the file path. (Also: result metadata — size/date/kind.)

### Quick actions palette
A ⌘K-style palette showing available actions for the selected row (open, reveal, pin, block, edit, delete, copy path).

### Snippet expansion
A command type that expands abbreviations: type "addr" → full address appears.

### Theme preview on hover
In Settings → Appearance, hovering a preset name temporarily applies it to the live preview.

### Motion & delight (Reduce-Motion-safe throughout)
Sliding pill (`matchedGeometryEffect`) gliding row-to-row; summon pop (0.96→1, 80 ms fade); pin jiggle / block poof (Dock-style) with the row icon in the HUD toast; boing ball spring-wobble on selection change, pixel rendition frame-stepping, idle float when empty; CRT power-on (120 ms flicker + vertical collapse on summon, phosphor fade on dismiss); Maker confetti on save; secret `boing`/Konami easter-egg (rainbow CRT + ball bounce once).

### Maker as instrument
Filter-budget profiler (staged-run ms vs the ~80 ms keystroke budget, auto-warn on `network`/`files`/`clipboard.read`); draft diff + one-click restore from `history/`; manual fix without regeneration (editable panes + revalidate); provider presets + keyless-local hint; transcript budget meter; output/log caps as honest UI ("showing last 6 of N — view all"); storage usage per command in Settings.

### Zero-UI smarts
Stale-frecency janitor (drop `app:` entries whose bundle no longer exists on `AppSource.reload`); per-engine keyword fallback (`g`/`yt`/`gh` rows above the generic web row); calculator-as-converter (`in`/`to` suffix grammar on the pin-first row).

### Command X-ray
Press Space on a command row to open X-ray as that row's Quick Look; file rows keep standard Quick Look. Show source, capabilities, generated provenance, last diff/runtime/error, and each `invoque.*` call beside its required permission. PR #58 supplies the first reusable source viewer.

### Rehearsal mode
Before a generated command's first real run, let bridge methods record "would open/write/run" effects and return fixtures. Label every simulated result unmistakably; never imply shell or network simulation proves safety.

### Universal action stack
Keep Finder selections, clipboard text, or result rows in a small stack, then send the stack to a compatible command. This combines LaunchBar Instant Send and Alfred File Buffer with Invoque's plain-file commands.

### Ghost completion
Render the top result as faint inline completion; Tab accepts the remaining title while Return retains normal execution. Learned abbreviations then feel immediate without destabilizing row order.

### Slow-command quarantine
Track duration and timeout counts. After repeated failures, show a health badge and remove the command from filter hot paths until the user retries or resets it. Link directly to bounded logs and a reason.

### Undo capsule
For reversible actions only, offer a short-lived capsule to restore clipboard contents, panel state, pin/block state, or a Maker revision. Clipboard snapshots must obey clipboard-history app exclusions and retention. Never claim undo for shell execution, deletion, restart, or shutdown.

### Make from no result
Offer `Make a command for “…”` as the last explicit no-result row. It must disclose that a configured model will be called and must never invoke the model from a habitual Return without visible confirmation.

### Signed command postcards
Export a read-only preview bundle containing manifest, source, permission summary, provenance, and a result sample. Import must verify the digest and a signature from a public key the user explicitly pinned by fingerprint; reject unsigned, unpinned, or mismatched bundles, open X-ray first, and keep execution separate.

---

## Stable-release validation matrix

- Signpost cold/warm hotkey-to-first-frame and query-to-rows p50/p95 on Intel and Apple Silicon with 0, 100, and 1,000 commands.
- Exercise file search on a large APFS home, whole disk, denied TCC folders, and a slow external SSD; verify cancellation, progress, sparse early emission, and explicit partial-result labels.
- Abuse every command boundary with infinite JS, shell descendants, oversized result arrays/strings, fetch bodies, logs, storage, fs reads/writes, and LLM output; prove bounded resources and honest truncation.
- Race source replacement and symlinks at loader, consent, runtime, storage, Maker save, history, and import boundaries; approved bytes must equal executed bytes.
- Manually verify mouse/keyboard destructive-action confirmation and paste Accessibility denial/recovery.
- Run VoiceOver, Full Keyboard Access, larger text, RTL, Reduce Motion, Reduce Transparency, Increase Contrast, multiple displays, and full-screen Spaces on macOS 13, 15, and 26 where available.
- Verify command-postcard import rejects unsigned, unpinned, and digest-mismatched bundles and shows only pinned-key-verified contents in X-ray.
- From a clean quarantined account, verify Developer ID identity, notarization, stapling, updater signature/version checks, replacement, relaunch, failure recovery, and rollback.

---

## Review follow-ups (declined or deferred during review, not forgotten)

- `amd64` arch-hint variant for the updater (`muse/fix-release-arch-date` review): `darwin-amd64` Intel builds tokenize to `[…, amd64]` which no hint matches — same as the old code (no regression), but adding `amd64` to the Intel-native / arm64-foreign sets would rank them correctly. Needs tests on both slices.
- `test()` run-signal (`muse/fix-maker-feedback-consent` review): `test()` silently no-ops while a consent card is up (intentional — the double-tap guard requires it), so future state bugs hide the same way. Follow-up: return a discardable `Bool` or debug-log when declining; an `assertionFailure` was rejected because it would crash the deliberate double-tap test in debug.
- `ISO8601DateFormatter(formatOptions:)` does not exist (review suggestion declined with evidence) — options are set post-`init()`, which the closure form already does.

---

## Implemented (done)

- ✅ Panel show/hide animation (fade + slide) — PR #32
- ✅ Source type badges on result rows — PR #36
- ✅ Clipboard history source — PR #39
- ✅ Edit command flow in Maker — PR #42
- ✅ Visual feedback for failed pin/block chords — PR #45
- ✅ Appearance reset restores the typeface — PR #28 (review round)
- ✅ Maker feedback clears stale consent — PR #29 (review round)
- ✅ HUD over fullscreen + clipped corners (+ continuous curve) — PR #30 (review round)
- ✅ Escaping command entry throws instead of trapping — PR #33 (review round)
- ✅ Arch hints match whole tokens; fractional dates parse — PR #34 (review round)
- ✅ Selection scrolling uses minimal edge movement instead of recentering — `f9dc77c`
- ✅ JavaScriptCore JIT entitlement matches PLAN — `c749e13` (release benchmarks and rationale remain above)
- ✅ Filter-command picks now train frecency — `99e0e32`
- ✅ Forced `web <query>` search mode — PR #48 (`swe.md` F2). `web ` routes straight to the web row when an app or file match would otherwise win; blank queries get a "type to search" hint instead of a dead Enter.
- ✅ Safer Empty Trash — PR #55 (`swe.md` B5/P4). Bulk deletion runs off the main thread, missing Trash counts as success, per-item failures HUD honestly, and `removeItem` attribution is regression-tested incl. dangling symlinks.
- ✅ `invoque.fetch` response cap — PR #57 (`swe.md` B6). Bodies spool to a temp file via `downloadTask` and are read back through `FileHandle` one byte past a 20 MB cap, so the read itself enforces the limit — no stat-then-read window, no `fileSize` reliance.
- ✅ Detached-window keyboard navigation — PR #59 (`swe.md` U9). PgUp/PgDn page by view height, Home/End and ⌘↑/⌘↓ hit the boundaries; shared `DetachedSearchModel.Boundary` semantics.
- ✅ Cancel button during Maker generation — PR #60 (`swe.md` B11). `discard()` cancels the in-flight task and returns to `idle` with the prompt intact; the cancelled task cannot clobber the phase.
- ✅ Commands settings tab — PR #63 (`swe.md` F3). Read-only inventory: loaded commands with mode/permission badges and consent state, directories, scan errors, roots with Reveal, activation-refresh on becoming key; atomic `scan()` snapshot; "Commands folder" menu item.
- ✅ Atomic selection updates on streamed results — PR #64 (`swe.md` B9). `PanelModel` routes every `results` write through `applyResults(_:tracking:)`; `DetachedSearchModel` sole-writes `rows`+`selection` with a same-value publish guard. No phantom top-selection between the rows write and the re-point.
- ✅ Footer status/hint split with result count — PR #65 (`swe.md` U3+V4). Separate clusters, file-scan progress, live counts, context-sensitive web hints, `.lineLimit(1)`.
- ✅ Action-command query arguments — PR #67 (`swe.md` B10/F6). `<trigger> <rest>` binds the trimmed remainder as `args[0]` when the first token case-insensitively matches the command's name or first keyword — the manifest `arguments` contract is finally reachable.
- ✅ In-flight work cancelled on panel hide — PR #41 (`swe.md` B3). File walks, filter runs (debounced *and* in-flight via the generation stale-drop), and Maker generation all cancel on dismiss.
- ✅ App catalog rescans on filesystem events — PR #50 (`swe.md` B7). `DirectoryWatcher` watches the search roots, retries failed opens on a self-scheduled cooldown (recovery notifies the consumer — the target was blind while it failed), and scans on a dedicated serial queue off the watcher path.
- ✅ README download link points at Invoque — `58cf2e9` (`swe.md` B1).

---

*Merged from `muse.md`, `glm.md`, the `sol.md` audit, and the `swe.md` review on 2026-09-21. Duplicates are consolidated; open review-round PRs remain listed until merged, and runtime-only macOS proof stays explicit.*
