# Invoque Code Review — mimo.md

Thorough review of the Invoque codebase (macOS launcher, Raycast/Alfred class).

---

## 1. Bugs

### 1.1 CalculatorSource integer overflow
`CalculatorSource.swift:283-284` — `Int64(value)` will trap on values between `1e15` and `Int64.max` (~9.2e18). The `abs(value) < 1e15` guard is too conservative — it rejects valid results unnecessarily — and too loose for values above `Int64.max` that pass it. Use `Int64(clamping:)` or check against `Double(Int64.max)`.

### 1.2 CarbonHotkey use-after-free window
`CarbonHotkey.swift:69` — `Unmanaged.passUnretained(self).toOpaque()` has a window between `InstallEventHandler` returning and the first event where deallocation would free the memory the callback reads. The current ownership model (controller-owned, long-lived) makes this practically safe, but it's a latent hazard. A `passRetained` + release in the handler (or an `Unmanaged` stored on the instance) would eliminate it.

### 1.3 FileSearchSession onStart can miss after cancel
`FileSearchSession.swift:84-91` — The debounce hop to main via `DispatchQueue.main.async` can queue after `finish()` already ran. The `isPending` guard catches this, but `onStart` never fires, silently missing the `fileRunsStarted` counter increment. Cosmetic today, but if `onStart` gains side effects it becomes a real bug.

### 1.4 PanelModel missing @MainActor
`PanelModel.swift:58` — The doc comment says "every member is main-queue confined" and asserts `@unchecked Sendable`, but the class lacks `@MainActor`. The compiler cannot enforce confinement at compile time. A race between a background `Task` callback and a keystroke could corrupt the model state silently.

### 1.5 CommandStore onChange is single-subscriber
`CommandStore.swift:31` — If two consumers both assign `onChange`, the second silently overwrites the first. The codebase works around this with one wiring point, but it's fragile. A multi-subscriber notification or Combine publisher would be more robust.

---

## 2. General Issues

### 2.1 PanelModel is a 932-line god object
`PanelModel.swift` owns query state, results, selection, filter mode, file-search mode, entry rules, maker routing, command results, and stability merges. It is the largest file in the codebase. The filter-mode logic (~200 lines) and file-search orchestration (~200 lines) should be extracted into separate types.

### 2.2 InvoqueBridge is a 638-line monolith
`InvoqueBridge.swift` has every JS module (storage, clipboard, fetch, fs, shell, paste, apps) as private static functions in one enum. Each could be its own type for independent testability and readability.

### 2.3 JSRuntime.opaqueRanges is fragile
`JSRuntime.swift:311-379` — The scanner handles strings, template literals, comments, and regex, but has known gaps: regex with `${}` nesting inside templates, regex flags, and nested template literals. The `isRegexPosition` helper (lines 387-423) is complex and fragile. Documented as a deliberate tradeoff, but worth noting.

### 2.4 Preferences init is 70+ lines of defaults loading
`Preferences.swift:398-470` — The initializer reads 25+ keys from UserDefaults with fallback chains. A property-wrapper pattern or `DefaultsSchema` struct would reduce boilerplate.

### 2.5 No UI tests
38 test files cover core logic well, but there are zero UI tests for panel positioning, focus management, or keyboard navigation. No integration tests for the full hotkey→panel→search→action flow.

---

## 3. Performance

### 3.1 FileSearch.resourceValues per entry
`FileSearch.swift:418-434` — Every visited file triggers `resourceValues(forKeys:)` to check `isHiddenKey` and `isDirectoryKey`. For a `home` scope with ~100K files, this sysattr fetch per entry adds up. The `cancellationStride` of 2048 mitigates responsiveness but not total cost.

### 3.2 FileSearch.sorted array rebuilt on every flush
`FileSearch.swift:334-336` — `boosted.sort(by:)` and `rest.sort(by:)` re-sort the entire accumulated arrays on every flush (every 48 matches or 120ms). With `maxMatches = 500`, intermediate sorts are redundant since the arrays are already sorted from the previous flush. An insertion-sort or sorted-insert approach would be cheaper.

### 3.3 InvoqueBridge.storage.get reads full JSON every call
`InvoqueBridge.swift:136-141` — Every `invoque.storage.get()` deserializes the entire `storage.json`. For a command with many keys, this is wasteful. The doc comment explains the rationale (avoid stale cross-invocation cache), but a memory-mapped file or in-memory cache with dirty-flag would help at scale.

### 3.4 SearchModel allocates per keystroke
`SearchModel.swift:105-182` — Every keystroke builds new `[ScoredItem]`, new `bestByID` dictionary, new sorted arrays, and new `Item` arrays. For ~50-100 items this is fine, but the comment says "the search hot path is allocation-light" — the allocations are not zero. A pre-allocated scratch buffer would help.

### 3.5 FuzzyMatcher lowercased copies per candidate
`FuzzyMatcher.swift:87-92` — `query.lowercased()` and `candidate.lowercased()` are called for every candidate, plus `Array()` conversions. For 50+ apps per keystroke this is ~100+ lowercased copies. A pre-lowered query would halve the work.

---

## 4. Missing Features (per PLAN.md)

### 4.1 notify is a log sink
`InvoqueBridge.swift:99-104` — `invoque.notify()` just logs. PLAN says "UNUserNotificationCenter needs the app's delegate wiring, so v1 sinks notify into the log." Documented as deferred.

### 4.2 exec runtime not implemented
`CommandManifest.swift:37-39` — `Runtime` only has `.js`. PLAN says `exec` (shebang subprocess) is "designed-for but post-v1."

### 4.3 view mode deferred
PLAN line 274: "deferred. Decision recorded."

### 4.4 Clipboard read + network exfiltration gap
PLAN lines 336-344: A command with `clipboard.read` + `network` permissions can silently exfiltrate clipboard contents. This is a known security gap.

### 4.5 No "Commands folder" menu item
PLAN line 449: "Commands folder is documented intent — the item isn't implemented yet."

### 4.6 No edit command flow
PLAN line 399: "`edit command <name>` enters the same flow seeded with existing files — not yet implemented."

---

## 5. UI/UX Issues

### 5.1 No animation on panel show/hide
`PanelController.swift:111-144` — `show()` calls `orderFrontRegardless()` and `hide()` calls `orderOut(nil)`. Hard cut, no fade-in/fade-out or scale animation. PLAN mentions "Small drop-in animation, none if Reduce Motion is on" but the implementation is a hard toggle.

### 5.2 Fixed panel size — not responsive to display
`PanelController.swift:16-18` — The panel is always 680x440 regardless of display size. On a 1080p external monitor this is fine, but on a Retina MacBook Air's smaller display or a 5K display, the proportions may feel off. A percentage-of-screen approach or a user-configurable size would be more flexible.

### 5.3 No visual feedback for failed pin/block chords
`LauncherPanel.swift:67-84` — `performKeyEquivalent` intercepts ⌘P and ⌘B unconditionally, but `PanelModel` returns nil for non-manageable rows. The chord is silently consumed with no feedback (no beep, no toast). The user has no indication why nothing happened.

### 5.4 No font size or panel size settings
`Preferences.swift` — The typeface is configurable but not the size. No user-configurable panel dimensions.

### 5.5 "Searching files..." has no progress indicator
`PanelView.swift:245-246` — When a file scan is pending, the panel shows text only. A spinner or progress bar would give better feedback.

### 5.6 No "open in new tab" or multi-result windows
The detached results window for file search is a good feature, but there's no way to open multiple result windows simultaneously or keep old results while starting a new search.

---

## 6. Visual / Theming Issues

### 6.1 No keyboard shortcut display in the panel
The footer shows "↑↓ navigate · ⏎ open · ⌘P pin · ⌘B block · esc dismiss" but doesn't show the summon hotkey itself or any app-specific shortcuts. Users might not know what hotkey summoned the panel.

### 6.2 No visual distinction between source types
App results, command results, system actions, and file results all look the same — same row style, same icon treatment. A subtle badge or color coding for source type (e.g., blue for apps, green for commands, gray for system) would improve scannability.

### 6.3 CRT overlay is all-or-nothing
The CRT effect applies to the entire card uniformly. A more nuanced approach — adjustable scanline density, a subtle curvature, or per-material CRT intensity — would make it more appealing.

### 6.4 No empty-state illustration
When the panel first opens with no query and no top hits, it shows "Search apps, commands, or the web" as plain text. A small, tasteful illustration or a curated "getting started" card would make the first-run experience warmer.

### 6.5 The Maker view feels utilitarian
The Maker (generate/test/save flow) is functional but visually plain compared to the launcher panel. Progress indicators, draft previews with syntax highlighting, and a more polished feedback loop would make command generation feel more like a creative tool and less like a form.

---

## 7. Novel / Creative Ideas

### 7.1 Typing sound effects
A subtle, optional click/tap sound on each keystroke (like a mechanical keyboard) would give the panel a tactile feel. Volume and pitch could be themeable. This is the kind of detail that makes Raycast feel premium.

### 7.2 Result row hover glow
When the mouse hovers a result row, a subtle glow or scale-up animation would add delight. The panel already tracks selection; adding a hover state with a lighter fill would make it feel more alive.

### 7.3 Typing speed adaptive UI
If the user types fast, reduce animation intensity. If they type slowly, allow more visual flourish. This is a subtle adaptive behavior that makes the panel feel responsive without being distracting.

### 7.4 Command dependency graph
For commands that call other commands or have complex workflows, a small dependency graph visualization in Settings → Commands would help users understand their command ecosystem.

### 7.5 Recent history sidebar
A ⌘R or right-arrow expansion that shows the last 10-20 actions taken, with timestamps and the ability to re-run or pin. This turns the launcher from a search tool into a workflow history.

### 7.6 Theme marketplace (local)
A folder of `.json` theme files that the Settings → Appearance panel browses like a gallery, with live preview on hover. Not a remote marketplace — just a local directory of themes the user or community shares via git.

### 7.7 Keyboard-driven command editing
`edit command <name>` (noted as missing) could open the Maker view pre-filled with the existing command's files, showing a diff view of changes. Combined with the feedback loop, this would make iterating on commands seamless.

### 7.8 Smart aliases
Auto-learning: if the user frequently types "par" and picks "Parallels Desktop", suggest "par" as a pin. The frecency system already tracks this; surfacing it as a suggestion in Settings or a toast would close the loop.

### 7.9 Multi-monitor panel positioning
Remember which display the panel was last shown on and default to it, or offer "always show on primary" / "always show under cursor" as a setting.

### 7.10 Clipboard history source
A `ClipboardSource` that captures recent clipboard entries (with timestamps) and surfaces them as searchable results. This is a common power-user feature in Raycast/Alfred and would be a natural fit.

### 7.11 Window management commands
Built-in system actions for window snapping (left half, right half, maximize, center) — common in Alfred/Raycast and useful without LLM generation.

### 7.12 Custom result row templates
Allow users to define custom row layouts in the theme — e.g., show the command's last-run time, or a subtitle with the file path for file results. This would be a `view`-mode precursor without the full Raycast extension complexity.

### 7.13 Quick actions palette
A ⌘K-style palette that shows available actions for the selected row (open, reveal, pin, block, edit, delete, copy path) — similar to VS Code's command palette. This would replace the context menu with a keyboard-first interface.

### 7.14 Snippet expansion
A command type that expands abbreviations: type "addr" → full address appears in the panel as a result. Simple `text→text` mapping without LLM. This is a common Alfred/Keyboard Maestro feature.

### 7.15 Theme preview on hover
In Settings → Appearance, hovering a preset name temporarily applies it to the live preview. This makes theme selection fast and visual.

---

## 8. Architecture Observations

### 8.1 Good patterns worth keeping
- The `ItemSource` protocol is clean and extensible.
- The stability merge in `stabilizedRankedRows` is well-thought-out.
- The permission system with consent cards and entry-hash binding is sound.
- The `FileSearchSession` streaming pattern with debounced batches is clever.
- The `AppearancePreset` import/export with Zap/Jetty compatibility is a nice ecosystem touch.

### 8.2 Areas for future attention
- The `EntryRules` closure-based design (one per preference) is flexible but fragile — a protocol with a concrete implementation would be more testable.
- The `CommandStore` FS watching could benefit from a proper FSEvent-based approach rather than polling (if not already using FSEvents).
- The Maker's single-shot LLM generation (no streaming) is documented as v1, but streaming would make the generation feel faster.

---

*Review complete. Focus areas for implementation: panel animation (5.1), source type badges (6.2), clipboard history (7.10), and keyboard-driven command editing (7.7) are the highest-impact, lowest-risk improvements.*
