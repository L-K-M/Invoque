# Invoque — Analysis & Future Work

High-quality, shovel-ready ideas for future development. Each item is
independently implementable and documented with enough context for an LLM
to pick it up.

---

## Bugs to Fix

### CalculatorSource integer overflow
`CalculatorSource.swift:283-284` — `Int64(value)` will trap on values between `1e15` and `Int64.max` (~9.2e18). Use `Int64(clamping:)` or check against `Double(Int64.max)`.

### CarbonHotkey use-after-free window
`CarbonHotkey.swift:69` — `Unmanaged.passUnretained(self).toOpaque()` has a window between `InstallEventHandler` returning and the first event where deallocation would free the memory the callback reads. A `passRetained` + release in the handler would eliminate it.

### FileSearchSession.onStart can miss after cancel
`FileSearchSession.swift:84-91` — The debounce hop to main can queue after `finish()` already ran. The `isPending` guard catches this, but `onStart` never fires, silently missing the `fileRunsStarted` counter.

### PanelModel missing @MainActor
`PanelModel.swift:58` — The class lacks `@MainActor` despite the doc comment saying "every member is main-queue confined." The compiler cannot enforce confinement at compile time.

### CommandStore onChange is single-subscriber
`CommandStore.swift:31` — If two consumers both assign `onChange`, the second silently overwrites the first. A multi-subscriber notification would be more robust.

---

## Performance Improvements

### FileSearch.resourceValues per entry
`FileSearch.swift:418-434` — Every visited file triggers `resourceValues(forKeys:)`. For ~100K files, this adds up. Consider batch-fetching or caching.

### FileSearch.sorted array rebuilt on every flush
`FileSearch.swift:334-336` — `boosted.sort(by:)` and `rest.sort(by:)` re-sort entire accumulated arrays on every flush. An insertion-sort or sorted-insert approach would be cheaper.

### InvoqueBridge.storage.get reads full JSON every call
`InvoqueBridge.swift:136-141` — Every `invoque.storage.get()` deserializes the entire `storage.json`. A memory-mapped file or dirty-flag cache would help at scale.

### SearchModel allocates per keystroke
`SearchModel.swift:105-182` — Every keystroke builds new arrays and dictionaries. A pre-allocated scratch buffer would help.

### FuzzyMatcher lowercased copies per candidate
`FuzzyMatcher.swift:87-92` — `query.lowercased()` and `candidate.lowercased()` are called for every candidate. A pre-lowered query would halve the work.

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

---

## Missing Features (per PLAN.md)

### notify is a log sink
`InvoqueBridge.swift:99-104` — `invoque.notify()` just logs. Needs `UNUserNotificationCenter` wiring.

### exec runtime not implemented
`CommandManifest.swift:37-39` — `Runtime` only has `.js`. PLAN says `exec` is "designed-for but post-v1."

### view mode deferred
PLAN line 274: "deferred. Decision recorded."

### Clipboard read + network exfiltration gap
PLAN lines 336-344 — A command with `clipboard.read` + `network` permissions can silently exfiltrate clipboard contents.

### No "Commands folder" menu item
PLAN line 449 — The menu item is documented but not implemented.

---

## UI/UX Improvements

### No settings for font size / panel size
`Preferences.swift` — The typeface is configurable but not the size. No user-configurable panel dimensions.

### "Searching files..." has no progress indicator
`PanelView.swift:245-246` — A spinner or progress bar would give better feedback during file scans.

### No empty-state illustration
When the panel first opens with no query and no top hits, it shows plain text. A small illustration would make first-run warmer.

### The Maker view feels utilitarian
The Maker is functional but visually plain. Progress indicators, draft previews with syntax highlighting, and a more polished feedback loop would make command generation feel more like a creative tool.

---

## Creative Ideas

### Typing sound effects
Optional click/tap sound on each keystroke (like a mechanical keyboard). Volume and pitch could be themeable.

### Result row hover glow
Subtle glow or scale-up animation on mouse hover. The panel already tracks selection; adding a hover state would make it feel more alive.

### Typing speed adaptive UI
If the user types fast, reduce animation intensity. If they type slowly, allow more visual flourish.

### Recent history sidebar
⌘R or right-arrow expansion showing the last 10-20 actions with timestamps and the ability to re-run or pin.

### Theme marketplace (local)
A folder of `.json` theme files browsed like a gallery with live preview on hover. Not remote — just a local directory.

### Smart aliases
Auto-learning: if the user frequently types "par" and picks "Parallels Desktop", suggest "par" as a pin.

### Multi-monitor panel positioning
Remember which display the panel was last shown on and default to it.

### Window management commands
Built-in system actions for window snapping (left half, right half, maximize, center).

### Custom result row templates
Allow users to define custom row layouts — show the command's last-run time, or a subtitle with the file path.

### Quick actions palette
A ⌘K-style palette showing available actions for the selected row (open, reveal, pin, block, edit, delete, copy path).

### Snippet expansion
A command type that expands abbreviations: type "addr" → full address appears.

### Theme preview on hover
In Settings → Appearance, hovering a preset name temporarily applies it to the live preview.

---

## Implemented (done)

- ✅ Panel show/hide animation (fade + slide) — PR #32
- ✅ Source type badges on result rows — PR #36
- ✅ Clipboard history source — PR #39
- ✅ Edit command flow in Maker — PR #42
- ✅ Visual feedback for failed pin/block chords — PR #45
