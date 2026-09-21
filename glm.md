# Invoque — GLM Code Review & Improvement Catalog

A full pass over the codebase at `bafb9d9` (v0.2.0, post #26). Scope: bugs,
general issues, performance, missing features, visual/layout problems, UX,
theming, and ideas. The reviewer read every production source file and the
plan/research docs; what follows is ranked by verified impact, not severity
labels. Praise is omitted — the engineering quality is visibly high (state
machines with epoch guards, stale-drop generations, capability-gated bridges);
this document is about what's wrong or missing.

---

## 1. Bugs & correctness issues

### B1. Pasted URLs search the web instead of opening — high value
`PathSource` resolves `file://` but nothing handles `http(s)`. Typing or
pasting `https://github.com` yields only the WebSource fallback
("Search the web for \"https://github.com\"") — ⏎ then *searches the engine
for the URL* instead of opening it. Alfred/Raycast/Spotlight all detect a
typed URL and offer "Open URL". Fix: a URL row pinned like `path:` (direct
intent), leaving the search fallback below it. Pure-logic, easily unit-tested
(`URLSource` twin of `PathSource`). * shovel-ready

### B2. Footer hint vs. actual Esc behavior on the consent card
`PanelView.footerHint` says "⌘⏎ allow · **esc dismiss**" while a permission
card is up, but Esc travels the responder chain to `LauncherPanel.
cancelOperation` → `PanelController.hide()` — the *whole panel* hides; the
card is only cleared by the next summon's `reset`. Two readings: (a) the hint
means "dismiss the panel" and is fine, or (b) Esc should decline the card and
return to results, matching "Don't Run". Either is defensible; today it's
ambiguous and the card state outlives the panel visibly. Decide + align
(copy or behavior). * small

### B3. ⇧⏎ secondary action promised by PLAN §3, absent
PLAN §3: "v1 has ⏎ = default action, ⇧⏎ = secondary." `SearchField`'s
`doCommandBy` handles `insertNewline:` without distinguishing Shift, so
⇧⏎ is identical to ⏎. Either implement a secondary action per row class
(open in new window, copy, etc.) or remove the claim from PLAN. * small

### B4. Empty subtitle still occupies a text line
`ResultRowView` always renders `Text(row.subtitle)`; filter rows, command
rows without a description, and error rows get a blank second line. All rows
share the taller two-line height, so the list wastes ~30–40 % vertical space
for subtitle-less rows. Conditional rendering (or `if !subtitle.isEmpty`)
tightens density without breaking alignment. * trivial

### B5. Maker inline fields can trap keyboard focus
`InlineField` (feedback, test args) becomes first responder on click; arrow
keys then edit the field, and there's no keyboard path back to the search
field (Tab order across the SwiftUI/AppKit mix is undefined here). Esc from
the field goes to `cancelOperation` → hides the panel entirely. A field-Esc
(or ⇥ backwards) should return focus to the search field first. Needs a
manual GUI check; flagged as suspected. * small, needs macOS verification

### B6. Selection auto-scroll centers on every arrow press
`.task(id:)` → `proxy.scrollTo(id, anchor: .center)` recenters the list on
every selection move; launchers conventionally scroll the *minimum* distance
so the list feels anchored (Raycast/Alfred keep the selection near the same
viewport position). `.center` makes long file lists jump a half-viewport per
keystroke. Consider visibility-aware anchoring (only scroll when the row is
out of view, edge-anchored). * small

### B7. HUD never dismisses if the app is inactive at fade time — cosmetic
`dismiss()` animates `alphaValue` then `orderOut`; `NSAnimationContext`
completion can be delayed when the app is background-throttled, so a toast
can linger seconds past 1.6 s. Minor; acceptable for a status-bar agent.

### B8. `search` keyword silently reroutes web queries — deliberate but sharp
`search foo` becomes a *file* scan while every other mental model says
"web search". README promises a release-notes callout. Consider `fs`/`files`
as a fourth alias and keeping `search` for the web fallback, or at least
showing a mode indicator in the footer (it does — "⏎ open · ⌘⏎ reveal").
Design decision; listed because it *will* generate bug reports. * decision

### B9. Frecency is invisible in file mode (documented) and in the empty panel
File ids are excluded from `recordSelection` and the file walk never reads
frecency — fine and documented. But see F1: frecency is also unused in the
one place it would shine, the empty-query panel.

---

## 2. Performance

### P1. Workspace icons resolved per row per render
`PanelView.iconImage(for:)` calls `NSWorkspace.shared.icon(forFile:)` for
every row on every SwiftUI body evaluation whenever the Pict resolver misses
(the common case for files). NSWorkspace's internal cache helps but still
allocates and can hit the disk for exotic files; with `maxResults = 50` rows
streaming in a file scan this is the most likely source of first-paint
stutter. An `NSCache<NSString, NSImage>` keyed by path (invalidated by the
same `noteIconsChanged()` path that clears the accent cache) is cheap.
* shovel-ready

### P2. FuzzyMatcher allocates four arrays per candidate per keystroke
`match()` builds `Array(lowered)`, `Array(candidate)`, `Array(query)` ×2 for
every item (hundreds of apps + system + commands) on every keystroke. AGENTS
explicitly says "keep the search hot path allocation-light." A UTF-8-view /
index-based scan with identical scoring would cut it to zero allocations.
Must preserve scores bit-for-bit (the tests + a snapshot test can pin this).
* shovel-ready, medium risk

### P3. `stabilizedRankedRows`/`stabilizedFileRows` re-match every survivor
Each keystroke re-runs `FuzzyMatcher.match` for every displayed row plus the
fresh candidates — doubling matcher work during extension typing. Given the
100 µs-scale matcher this is minor; only worth folding into P2.

### P4. File-search flush sorts the full accumulated set per batch
`flush()` re-sorts `boosted` + `rest` (up to 500) on every 48-match batch —
O(n log n) per stride, fine at current caps. Note only: if `maxMatches`
grows, switch to incremental merge. No change needed now.

### P5. `Frecency.record` encodes + persists the whole table per Return
One JSONEncoder + UserDefaults write per launch pick; rare and small. Fine.
Listed for completeness — do not touch.

---

## 3. Missing features (ranked by user value)

### F1. Empty-query panel shows nothing — frecency top hits missing
Summoning the panel with an empty query shows "Search apps, commands, or the
web" and a dead list. Every peer launcher (Spotlight, Alfred, Raycast) shows
*something*: recent/frequent launches. The frecency data, sources, and
ranking machinery already exist; `SearchModel.results` just early-returns on
blank queries ("Empty or blank queries yield no results" is even documented
as intended). Returning frecency-ordered top hits (capped ~8, apps +
commands + system, only entries the user actually launched before) turns the
most-visited surface in the app from a hint string into a launcher.
Zero-state users still see the hint (empty frecency → hint). * shovel-ready,
plan change required (update PLAN §3 + SearchModel doc)

### F2. ↑ does nothing on an empty list — no query history recall
Alfred's most-used muscle memory: ↑ through previous queries. `moveSelection`
guards `!results.isEmpty` and returns; nothing anywhere persists query
history. A small ring buffer of recent queries (UserDefaults, like frecency)
surfaced when the query is empty (or when ↑ is pressed at the top of the
list with a non-empty query) is high value per line of code. * shovel-ready

### F3. No copy affordance: ⌘C on a row does nothing
Rows have ⏎ and ⌘⏎ (open/reveal). Copying the selected row's path/URL/title
— the third most common launcher action — has no keyboard path (Finder-style
⌘C). `LauncherPanel.performKeyEquivalent` already intercepts chords; a ⌘C
case there (copy file path, URL, or title by action class) is ~30 lines.
* shovel-ready

### F4. Settings tabs promised by PLAN §7 are absent
PLAN §7 lists six panes; SettingsView has two (General, Appearance). Missing:
**Commands** (loaded list with mode/permissions/origin, enable-disable,
roots management — `CommandStore.scanErrors` has no UI surface at all, so a
broken `command.json` is *completely invisible* to the user), and
**Permissions** (Accessibility status for `paste` commands, deep link). The
status menu's "Commands folder" item is documented intent, unimplemented.
* medium, shovel-ready in slices

### F5. `invoque.notify` is a log sink
Documented TODO: `notify` writes to the command log and never reaches the
user. `UNUserNotificationCenter` needs delegate wiring; a HUD toast (the
infrastructure already exists, themed even) is the cheap 90 % path — an
action-mode command showing `{title}` already HUDs, so notify could reuse
exactly that. * small

### F6. Maker: `edit command <name>` and revision rollback absent
PLAN §6 documents both as designed-but-unimplemented; the writer already
snapshots `history/`. Editing is the more valuable half — the Maker can only
create from scratch today, and iteration means regenerating from a prompt.
* medium

### F7. Calculator gaps: no `pow`, no `%`, no hex/bin, no unit conversion
The parser is deliberately safe (good), but `pow(2,10)` fails because commas
never tokenize; `0x1f` and `0b1010` are rejected by the charset gate; unit
conversion (`10km in mi`, `72f in c`) doesn't exist. A base-conversion row
(hex ⇄ dec ⇄ bin for any typed integer) is trivial and delightful; offline
unit tables are ~150 lines of pure logic, fully testable. * shovel-ready in
slices

### F8. Web fallback is a single engine with no direct prefixes
One configured engine, one fallback row. Peer launchers offer direct engine
routing (`g query` → Google, `ddg query` → DuckDuckGo). Also the fallback
row list could show 2–3 engines simultaneously. * small

### F9. Clipboard history / snippets — the classic launcher pillar
PLAN lists it as a candidate; nothing exists. Files-as-database philosophy
maps well (`~/.config/invoque/clipboard-history.jsonl`), but privacy surface
(password-manager `ConcealedType` filtering, opt-in apps) makes it a real
project. * large, future

### F10. Running-apps source (quit/kill)
`NSWorkspace.runningApplications` could offer "Quit <app>" / force-quit rows
(`kill Safari`). TCC implications for `terminate()` need verification on
modern macOS; scope as `quitapp` only if no AppleEvent consent is required.
* idea, needs research

### F11. Quick Look on file rows
Space (Finder muscle memory) on a `file:`/`path:` row opens Quick Look.
`QLPreviewPanel` in a nonactivating panel is fiddly; `qlmanage -p` is a
process spawn. Delightful if it can be made robust. * idea

### F12. Dictionary lookup (`define word`)
`DCSCopyTextDefinition` is a public offline API; `define serendipity` →
dictionary snippet row. Fully offline, no permission. * idea, small

---

## 4. Visual issues, layout & theming

### V1. No matched-text highlighting in titles
The single biggest visual gap. Spotlight/Alfred/Raycast bold (or tint) the
characters that matched the query; Invoque's titles are uniform text, so the
eye must re-find the match per row. The matcher's tier classification
already knows prefix vs infix; a contiguous-infix range can be highlighted
exactly (simple case-insensitive range search at render time), and fuzzy
rows left unhighlighted rather than approximated. Needs the match range (or
just the query) plumbed to `ResultRowView` — the row already receives
everything else. * shovel-ready, high visual payoff

### V2. No hover state on rows
Mouse users get no feedback until click (no hover background, no point
cursor). A faint `onHover` fill at a fraction of the selection opacity, and
`.pointerStyle(.link)`-equivalent, makes the list feel alive with ~10 lines.
* shovel-ready

### V3. Panel pops in with no animation
PLAN §3: "Small drop-in animation, none if Reduce Motion is on" — not
implemented; `orderFrontRegardless` snaps. A 120 ms fade + 8 pt slide (or a
subtle scale from 0.98) on show, and a quick fade on hide, would match the
polish level of everything else. `AccessibilityDisplaySettings.
effectiveAnimation` already exists for the gate. * small, needs macOS
verification (can't be CI-tested)

### V4. Fixed 680×440 panel, no size or position settings
PLAN §7.1 promises "panel position basics"; nothing. A compact/regular/
large width setting (three fixed sizes keeps the fixed-height model) is
cheap; free resizing fights the whole fixed-card design and isn't worth it.
* small

### V5. Placeholder is just "Search"
The empty-state hint text at the bottom of the list does the teaching; the
field itself could carry it ("Search apps, commands, files…"). Trivial, but
every keystroke of guidance in the field is one fewer trip to the docs.
Also: the hint string lives in `PanelView` and duplicates knowledge of the
sources. * trivial

### V6. Solid/gradient themes vs. system controls inside the card
MakerView's `Button`s, ProgressViews, and the consent card's buttons keep
system styling; on a dark Synthwave `solid` fill with a light label color
the tinted default buttons can clash. A `.buttonBorderShape`/custom label
color pass (or `.tint()` with the theme highlight) would keep the card
coherent. * polish, needs visual iteration on macOS

### V7. Pin indicator is easy to miss
A tiny `pin.fill` glyph at 65 % opacity trailing the row. A pinned row
should read instantly — consider leading-position badge or a slightly
stronger treatment. * polish

### V8. CRT overlay sits over the search field text
`CRTScreenOverlay` draws over content including the query — thematically
correct ("over the content too") but at high intensity the scanlines cross
the one line of text users are actively reading. Consider excluding the
header row from the overlay (clip to the list area) when intensity > ~0.7,
or offering the choice. * decision, minor

---

## 5. User experience / convenience

### U1. The panel is the only input surface — no way to paste into it
⌘V into the search field works (NSTextField), good. But pasting a *path* to
detach is the common flow and it works; pasting an image (e.g. to save to a
file / reverse-search) does nothing. Multi-type pasteboard handling
(image → temp file → PathSource row) is a quirky-but-loved Raycast feature.
* idea, medium

### U2. No result-count or scan-progress indicator in the panel
File mode shows "Searching files…" but not how far (visited count is known
to the walk). A subtle "1,204 visited · 37 matches" ticker in the footer
during scans makes long walks feel trustworthy. * small

### U3. Blocked-list management is a dead end
Settings → Pinned & Blocked is "the only place to undo a block" — correct,
but the list shows raw ids (`app:com.apple.Safari`) under titles; fine.
Missing: search/filter within the lists once they grow. * minor

### U4. No onboarding for the Maker
`make` requires Settings → AI configured first; typing `make command…` with
no API key goes straight to a transport failure. The idle MakerView should
detect "no key stored" and link to the Settings pane. * small, high value
for the flagship feature

### U5. Command errors surface as one HUD line only
A failed command run shows `error.localizedDescription` in the HUD for 1.6 s
— long stack-style output is unreadable and uncopyable. The filter path
shows error rows (good); the action path could offer "Copy error" on the
HUD or a result row instead. * small

### U6. Detached file window: no re-query
Once detached, the window is read-only — no way to refine the search text
without re-summoning the panel and re-walking. An editable header field
re-running the (debounced) walk inside the same window is the natural
completion of the feature. * medium

---

## 6. Delightful / novel / quirky ideas

### D1. "Large Type" — Alfred's most showy feature, missing here
⌘T (or an action) shows the selected row's text (calc results especially)
in a huge HUD-style overlay across the screen. Invoque's HUD + theming
infrastructure makes this nearly free, and it pairs perfectly with the CRT/
retro identity (imagine Large Type under scanlines). * shovel-ready, small

### D2. Built-in quick generators: `uuid`, `ulid`, `roll d20`, `flip`, `now`
`uuid` → a row that copies a fresh UUID; `now` → ISO-8601 timestamp +
relative variants; `roll d20`/`flip coin` for the fun of it. Pure logic,
trivially tested, and they make the empty panel useful in demos. Could be
one `GeneratorsSource`. * shovel-ready

### D3. SF Symbols browser: `sym star` → symbol rows, click copies the name
A developer-delightful source matching SF Symbol names (`sym` prefix), each
row rendering the symbol itself, ⏎ copies the name, ⌘⏎ copies
`Image(systemName:)` snippet. Fits the "keyboard-first, plain files" ethos;
pure in-memory data. * idea, medium (needs a symbol-name table)

### D4. Base-conversion row for any integer input
Typing `255` is just a number; typing `0xff`/`0b11111111` or `255` with a
`hex`/`bin` tail row showing dec/hex/bin/oct would be calculator-adjacent
delight. See F7. * shovel-ready with F7

### D5. Theme "shuffle" / seasonal flourishes
The preset system is JSON; a hidden `make me pretty` style easter egg that
generates a random harmonious palette (HSL rotation) as a one-off preset
would fit the Maker identity. * quirky, small

### D6. Panel sound design (off by default)
A soft 12 ms "tick" on summon and a lower one on dismiss, using `NSSound`
or generated samples, behind an Appearance toggle defaulting to off.
Launchers with sounds polarize; default-off keeps it a delight for those
who opt in. * idea

### D7. "Boing" the ball — tap the Amiga decoration
The boing ball decoration is static; a click (it's currently
`allowsHitTesting(false)`) could bounce it once across the card. Pure joy,
guarded by Reduce Motion. * quirky

### D8. Command of the day
The empty panel (F1) could occasionally surface a built-in capability the
user hasn't tried ("did you know: `find ` walks the disk without
Spotlight?") as a subtle footer line. * idea

---

## 7. Structural / architectural observations

### S1. `PanelModel` is 932 lines and accreting modes
Normal search + filter + file mode + maker routing + consent + pin/block +
detached-session handoff all live in one class with interleaved cancel
functions. The invariants are documented and tested, but the next mode
(clipboard history, URL source) will make it unwieldy. A mode enum with
per-mode state (like `MakerModel.Phase`) is the natural refactor — do it
*before* F1/F2/F9 land more branches in `refreshResults`. * refactor,
medium

### S2. `SearchModel.results` duplicates slot math with
`PanelModel.stabilizedRankedRows`
`middleSlots`/`bandCap` calculations are copy-paste variants; the stability
merge reimplements the ranking keys. A shared `rankedSlots(pins:web:)`
helper would prevent drift. * small refactor

### S3. Tests are strong for logic, zero for layout
No snapshot/preview tests for `PanelView`, `ResultRowView`, `MakerView`.
SwiftUI layout regressions (B4-class) are invisible to CI. A few
`PreviewProvider`-driven snapshot tests (or at least frame-invariant
assertions) would catch visual drift. * medium, macOS-only CI

### S4. `notify`/`console.error` log levels are indistinguishable in UI
CommandLog flattens everything to strings; the Maker test view shows the
last 6 lines regardless of level. Minor.

---

## 8. What I would implement first (shovel-ready shortlist)

Ordered by value/effort, all testable in pure logic (CI-verifiable without
a GUI session):

1. **F1 — frecency top hits on the empty panel** (plan update + model + tests)
2. **B1 — typed/pasted URL row** (`URLSource`, pinned like `path:`)
3. **V1 — matched-text highlighting** (title ranges plumbed to the row view)
4. **F2 — ↑ query history recall** (ring buffer + empty-list behavior)
5. **F3 — ⌘C copies the selected row** (path/URL/title by action class)
6. **V2 + B4 — hover fill + compact subtitle-less rows** (view polish pair)
7. **F7/D4 — calculator: hex/bin input + base-conversion row**
8. **D2 — generators source (`uuid`, `now`, `roll`)**

Deferred as needing macOS manual verification or design decisions: V3
(show animation), B2/B3 (Esc/⇧⏎ semantics), B5 (Maker focus), F4 (Settings
tabs), F5 (real notifications), V6 (control theming).

The two perf items (P1 icon cache, P2 matcher allocations) are shovel-ready
but rank below the UX shortlist; P1 first if any stutter reports arrive.

---

*End of review. Implementation branches follow, one PR per idea, cut from
latest `origin/main`.*
