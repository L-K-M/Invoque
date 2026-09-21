# Invoque — A macOS Launcher That Writes Its Own Commands

A fast, keyboard-first launcher in the Raycast/Alfred class. On top of the usual
search/launch/calculate features, commands are plain files on disk — a
`command.json` manifest plus a `main.js` script — and a built-in `make` command
asks a configured LLM to write new commands on the fly, then test and refine
them without leaving the panel.

See `RESEARCH.md` for the survey and engine evaluation this design is based on.

---

## 1. Goals & Non-Goals

### Goals
- Spotlight-style floating panel on a global hotkey; instantly typeable, hides
  on Esc and on losing focus.
- Built-in sources: apps, commands, calculator, system actions, direct
  filesystem paths, web-search fallback. (Clipboard history/snippets are
  candidates — pick by scope.)
- Custom commands as two plain files in a commands directory — inspectable,
  hand-editable, git-able. Hot-reloaded on save.
- `make` command: natural language → generated `command.json` + `main.js` →
  in-panel test → feedback loop → save.
- Capability-gated script API: generated code gets only the permissions its
  manifest declares.
- Zero required TCC permissions for core features (see §5).

### Non-Goals (v1)
- Raycast-style `view` mode (script-driven rich UI). Filter items + a result
  panel cover the generated-command use cases; revisit later.
- A command store/sharing. Commands are local files; sharing is `git push`.
- Subprocess (`exec`) runtime — documented escape hatch, second phase.
- App Store distribution (same as Zap: Developer ID + notarization).

---

## 2. High-Level Architecture

A background **agent app** (`LSUIElement = true`, no Dock icon).

```
┌──────────────────────────────────────────────────────────────┐
│ Invoque (LSUIElement agent app)                               │
│                                                               │
│  ┌─────────────┐    ┌───────────────────────────────────┐    │
│  │ Hotkey      │    │ ItemSources                        │    │
│  │ (Carbon     │───▶│  Apps · Commands · Calculator ·    │    │
│  │  ⌥Space)    │    │  System · Web fallback             │    │
│  └─────────────┘    └──────────────┬────────────────────┘    │
│                                    ▼                          │
│                        ┌──────────────────────┐              │
│                        │ SearchModel          │              │
│                        │  fuzzy match + rank  │              │
│                        └─────────┬────────────┘              │
│                                  ▼                            │
│              ┌───────────────────────────────────┐          │
│              │ LauncherPanel (NSPanel            │          │
│              │  .nonactivatingPanel + SwiftUI)   │          │
│              └───────────────────────────────────┘          │
│                                                               │
│  ┌──────────────────┐    ┌───────────────────────────────┐   │
│  │ CommandStore     │    │ JSRuntime (JavaScriptCore)     │   │
│  │  scan + FS-watch │───▶│  per-command JSContext,        │   │
│  │  command dirs    │    │  invoque.* bridge, perm gate   │   │
│  └──────────────────┘    └───────────────────────────────┘   │
│            ▲                          │                       │
│            │ writes                   ▼ runs drafts           │
│  ┌─────────┴──────────┐   ┌───────────────────────────────┐  │
│  │ CommandMaker       │◀──│ LLMClient (OpenAI-compatible   │  │
│  │  generate→test→fix │   │  + Anthropic, key in Keychain) │  │
│  └────────────────────┘   └───────────────────────────────┘  │
│                                                               │
│  StatusItem → Settings (LLM config, hotkey, commands dirs,    │
│  permissions status)                                          │
└──────────────────────────────────────────────────────────────┘
```

**Tech stack:** Swift, SwiftUI for panel content and Settings, AppKit for
windowing (`NSPanel`, `NSStatusItem`), `JavaScriptCore` for the command runtime,
`NSWorkspace` for app listing, `UserDefaults` for preferences. One
dependency: [`PictKit`](https://github.com/L-K-M/Pict), the first-party
SwiftPM package holding the shared icon store and resolution ladder Zap,
Jetty and Top Drawer already link. Otherwise no third-party dependencies.
Targets macOS 13+ (revisit if Zap has since raised its floor).

---

## 3. The Panel

- `NSPanel` subclass, styleMask `[.nonactivatingPanel, .borderless]` (or
  `.titled` + `.fullSizeContentView` for the shadow), `canBecomeKey = true`,
  `level = .statusBar`, `collectionBehavior` with `.canJoinAllSpaces`,
  `.fullScreenAuxiliary`, `.stationary`. Transparent background; SwiftUI
  `NSHostingView` draws the card.
- Spotlight position: horizontally centered, top edge ~25 % down the screen,
  on the display under the cursor. Small drop-in animation, none if Reduce
  Motion is on.
- Esc cancels (`cancelOperation`); hide on resign-key. Re-show starts with the
  query cleared (or optionally remembered — setting).
- Layout: search field on top, results list below, footer with
  action hints. ⌘K-style action panel per result is a later refinement; v1 has
  ⏎ = default action, ⇧⏎ = secondary.

### Theming

The family's appearance system (Zap/Jetty conventions) drives the card:

- **Material** (`PanelMaterial`): Liquid Glass / Clear / Tinted on macOS 26
  via `.glassEffect`, `NSVisualEffectView` (`.popover`) fallback below, or the
  user's own `solid`/`gradient` fill with tint, gradient end, angle
  (`AngleDial`) and opacity. Reduce Transparency forces fills opaque.
- **Selection**: highlight color + opacity + corner radius. Selected-row text
  is luminance-aware (`Color.readableForeground`, TopDrawer's rule) against
  the fill *composited over* the card's base color — at low opacity the
  background dominates, so the raw highlight alone would choose wrong.
- **Adaptive accent**: when on, the selected row's *drawn* icon supplies
  the fill — `CIAreaAverage` dominant color, saturation-boosted, cached by
  icon path and invalidated with the shared store (Jetty's `TileAccent`
  transplanted to the launcher). `.symbol` rows fall back to the theme
  highlight.
- **Text**: `labelHex` applies only where the theme owns the background
  (`solid`/`gradient` — `PanelMaterial.usesThemeTextColor`); glass defers to
  the system, which adapts `.primary` to the appearance. `panelTypeface`
  picks the face — four system designs plus any installed font family
  (`PanelTypeface`; the picker leads with a curated set, then lists every
  installed family), applied to every panel text: rows, query field, maker,
  consent card, footer, HUD. SF Symbol icons keep the system face.
- **Retro flourishes**: corner `PanelDecoration` (ZX stripes, boing ball) +
  `CRTScreenOverlay`, copied from Zap.
- **Presets** (`AppearancePreset`): Codable snapshot + built-ins (Classic,
  Summon — the signature violet cockpit — Graphite, ZX Night, Vaporwave,
  Synthwave, Memphis, Amiga) + JSON import/export. Synthwave and Memphis
  mirror the `media-sources/` icon art — night and day halves of the same
  palette. The decoder sniffs keys and accepts **Jetty**
  and **Zap** theme files too; Invoque's own field names match Jetty's where
  they coincide, so exports import into Jetty.

### Search model
- `ItemSource` protocol: `func items(for query: String) -> [Item]` (sync,
  cached sources) and async `reload()` for dynamic ones.
- Sources v1: `AppSource` (NSWorkspace scan, LaunchServices apps), 
  `CommandSource` (from CommandStore), `CalculatorSource`, `SystemSource`
  (lock/sleep/restart/empty trash…), `PathSource` (a pasted/typed
  filesystem path that exists pins first — ⏎ opens folders, reveals
  files in Finder; ⌘⏎ is the inverse), `WebSource` (fallback "Search
  for X" against the configured `SearchEngine` — Settings → General).
- `CommandStore` performs its initial disk scan and watcher setup off-main;
  the panel can render immediately and `CommandSource` republishes on arrival.
- Consequential system actions (restart, shutdown, empty Trash) replace the
  list with a trusted confirmation card. Only its button or ⌘⏎ dispatches;
  plain Return remains neutral. Lock and sleep stay immediate.
- File search: `find <query>` / `f <query>` / `search <query>` routes to a
  built-in file mode — a direct `FileManager` walk, **not**
  Spotlight/NSMetadataQuery (metadata misses excluded locations). What it
  walks is a Settings choice (General → "File Search"), persisted as a set
  of scopes: **home** (`~/`, the default — on the boot disk only the home
  folder makes sense), **system** (the whole startup disk minus `/Volumes`
  and `/System/Volumes` — the data volume is already reachable through
  the firmlinks at `/`, and walking its real mount point would list every
  user file twice — and minus `~` when home is also on, so overlapping
  scopes never double-walk a tree), and **volumes** (every mounted local
  volume that isn't the boot disk, searched in full — other drives have
  no home folder, though a relocated `~` on one is still skipped when
  home is on; network shares are skipped since a per-keystroke remote
  walk isn't interactive). Scope roots resolve per query, so a drive
  mounted mid-session joins the next scan. Hidden directories (`~/Library`,
  `.git`) and dependency trees (`node_modules`, `Pods`, `venv`) are pruned
  (case-insensitively); generic build dirs (`target`, `build`, `dist`) are
  pruned only beside a project manifest, so a hand-made `Documents/build`
  stays findable. Hidden files in visible dirs still match. Debounced
  ~150 ms, cancellable, capped on visited entries and matches, stale
  results discarded; the panel shows a "Searching files…" hint while a
  scan is in flight rather than a premature "no matches". Matches
  stream into the list as the walk finds them — a `FileSearchSession`
  owns the debounce and the accumulated ranked snapshots (throttled by
  count and interval), so progress is visible instead of one batch at
  the end. ⏎ while the scan is still streaming detaches the session
  into its own titled results window — the same walk keeps streaming
  there, and its rows stay openable/revealable/pinnable/blockable;
  closing the window retires the scan. Once the scan settles, ⏎ opens
  the file and ⌘⏎ reveals it in Finder (also on app rows). Caveat:
  TCC-guarded folders (Desktop,
  Documents, Downloads) need the system consent prompt on first access —
  the walk silently skips what it can't read.
- Fuzzy matcher: small fzf-style scorer (subsequence bonus, word-boundary
  bonus, case bonus). Pure function — unit-test it. Zap's type-to-search
  matching is the local precedent.
- Ranking: match tier first — exact prefix > exact infix > fuzzy
  subsequence — then a match that lands in the displayed title beats a
  hidden-surface hit (matchText carries extra matchable words invisible
  to the user), then shorter title, then frecency
  (persisted usage counts in UserDefaults), then the alignment score,
  then title/id for a total order. Pinned rows keep their slots:
  `PathSource` rows first (a typed address is a direct intent),
  calculator answers next, web fallback last.
- Empty query — top hits: the freshly summoned panel lists what the user
  actually launches — frecency-recorded apps, commands, and system
  actions, best score first, capped at nine (blocked ids honored, and
  only the same durable namespaces `recordSelection` trains are
  eligible). With no history yet the panel shows its input hint instead.
  A top-hit pick records through the normal selection path — the rail
  reinforces itself exactly like any other launch.
- Entry rules: the user can **pin** a durable entry (⌘P or right-click →
  Pin — ranks above unpinned matches when it matches, beneath the `path:`
  and `calc:` head rows; a pin boosts, it doesn't conjure, and pins past
  the result cap rejoin ranked order) or
  **block** one (⌘B — never appears; the sets are exclusive — blocking
  unpins, pinning unblocks — so the last explicit action wins). Apps,
  commands, system actions and file hits
  are entries; `path:`/`calc:`/`web:` functional pins and ephemeral
  `filter:` rows aren't. Both sets persist in UserDefaults as id→title
  and are managed from Settings → General ("Pinned & blocked") — the only
  place to undo a block, since a blocked row can't be selected. A change
  re-lists the open panel on the spot; in `find`/`f` mode the cached scan
  reshapes without re-walking the disk.
- Stability: extending the query preserves the displayed order of rows
  that still match — a row the user is reaching for never moves under
  them — *among equal-ranked peers*. The merge sorts by (pinned, match
  tier, title-visible hit): a row whose fresh rank is strictly better
  promotes past worse rows, so typing "para" surfaces "Parallels Desktop"
  rather than holding it below fuzzy survivors, while equal-keyed rows
  keep their slots (a degrading survivor isn't churned by same-tier
  reshuffles). Non-extension edits (deletion, replacement, mode switches)
  re-rank fresh. Rows that match for the first time mid-extension (a
  streamed file hit, a refreshed source) join by the same merge — below
  equal-ranked survivors, above worse ones. The same holds for `find`/`f`
  scan completions.
- Icons: result-row bitmaps resolve through `PictKit`'s `IconResolver`
  (`InvoqueIcons`, the `JettyIcons`/`ZapIcons` seam) — a user-set icon in
  Pict (or any family app) wins, then the bundle's own un-jailed artwork,
  then the `NSWorkspace` icon on a miss, which also warms in the
  background. App rows are `.application` targets (path rung, then
  bundle-id rung — SSB wrappers stay told apart); file-search rows are
  `.file` targets, `.app` packages included. `IconStoreWatcher` republishes
  the panel when another app rewrites the store; the adaptive accent
  samples the *drawn* image, so a custom icon glows its own colors.

---

## 4. Custom Commands

One directory per command under a watched commands root (default
`~/.config/invoque/commands/`; additional roots configurable — symlink a git
repo in to sync commands between machines).

```
format-clipboard-json/
├── command.json
├── main.js
├── data/            # scratch dir, always writable by the command
└── history/         # timestamped snapshots of previous revisions
```

### 4.1 Manifest

```json
{
  "schemaVersion": 1,
  "name": "format-clipboard-json",
  "title": "Format Clipboard JSON",
  "description": "Pretty-print the JSON currently on the clipboard",
  "runtime": "js",
  "entry": "main.js",
  "mode": "action",
  "arguments": [{ "name": "indent", "type": "text", "optional": true }],
  "keywords": ["json", "fmt", "pretty"],
  "icon": "curlybraces",
  "permissions": ["clipboard.read", "clipboard.write"],
  "generated": { "prompt": "…", "model": "…", "revision": 2 }
}
```

Modes:
- `action` — runs once; return `{title}` → HUD, or `{items}` → show results,
  or nothing → silent. (Folds Raycast's silent/compact/fullOutput into one.)
- `filter` — re-runs on each keystroke (debounced ~80 ms, stale results
  discarded); returns `{items:[{title,subtitle,icon,arg,actions}]}` — Alfred's
  shape. Routing: `<keyword> <rest>` switches the panel into the command's
  live list (first `keywords` entry is the trigger; the command name is the
  fallback; when a command's name collides with another command's trigger
  keyword, the named command wins, and a picked `.enterFilter` row pins the
  session to that command regardless). Picking a row uses `arg`: an
  `http(s)` URL opens, anything else
  copies to the clipboard, and no `arg` copies the title.
- `view` — **deferred.** Decision recorded: if added, declare UI as data
  (list/detail spec the app renders natively) rather than embedding a React
  runtime.

`runtime: "exec"` (run a shebang script, JSON on stdout) is designed-for but
post-v1.

### 4.2 JS runtime

- Each command gets a fresh `JSContext` per invocation, created and used on a
  dedicated serial queue. No shared state between invocations; `storage` is the
  persistence path.
- Injected `invoque` global is assembled **per manifest permissions** —
  undeclared modules are absent from the context entirely. Modules v1:

  | Module | Permission | Notes |
  |---|---|---|
  | `storage` | — (always) | per-command key-value store under `data/` |
  | `args`, `log`, `notify` | — (always) | args, os_log, HUD/notification |
  | `open` | `open` | `NSWorkspace.open` — http(s) only; gated because query strings are an egress channel |
  | `clipboard` | `clipboard.read` / `clipboard.write` | NSPasteboard |
  | `fetch` | `network` | URLSession wrapper, returns text/JSON |
  | `fs` | `files` | scoped to `data/` + user-granted paths |
  | `apps` | `apps` | `list()` → `{name, path, bundleID}` (AppCatalog scan, shared with AppSource); `launch(name \| bundleID \| path)` — exact match, `NSWorkspace.open`; path targets confined to catalog members. Withheld in filter mode |
  | `paste` | `paste` | `text(t)` — clipboard write, re-activate frontmost app, simulate ⌘V; needs the app-level AX grant (lazy `AXIsProcessTrustedWithOptions` prompt on first call). Withheld in filter mode |
  | `shell` | `shell` | `/bin/sh -c`; first-run confirmation sheet |

  Migration: commands written before `open` was gated must add `"open"` to
  `manifest.permissions` (or be regenerated) — otherwise `invoque.open` is
  `undefined` and calls throw a `TypeError`.

- Errors: `context.exceptionHandler` → surfaced in-panel and logged.
  Async contract: entry point is `export default async function`; a tight
  synchronous loop cannot be interrupted — on timeout the context is abandoned
  and its result discarded (documented limitation; the generator's system
  prompt forbids unbounded sync loops).
- Calculator and "eval JS" can reuse this engine — one runtime, three uses.

### 4.3 Permissions UX

- Declared in the manifest, visible on the command's detail line (small lock
  badge). First run of a `shell`/`paste` command pauses at the run boundary
  and shows an in-panel consent card spelling out each risky permission —
  ⌘⏎ or the Allow button grants (plain ⏎ is neutral, so a habitual
  double-⏎ can't record a permanent grant); "Don't Run"/esc declines.
  Grants persist in UserDefaults keyed by command name plus a hash of the
  entry file — consent attaches to the entry bytes the user approved, so
  regenerated, replaced, or same-named entry code re-asks, and a manifest
  that gains a risky permission re-asks for that one only. (Widening the
  key to hash auxiliary files is a follow-up once commands actually ship
  executable siblings — today nothing can `require` them, though a
  `shell`-permitted entry could `exec` one.) The Maker's Test button
  applies the same gate to generated drafts. **Trust boundary:** the
  defaults domain is writable by any user-context process — including a
  previously-consented `shell` command — so grant records are forgeable
  and the store is a UX consent ledger, not a tamper-proof security
  boundary. Making records tamper-evident (HMAC over name + hash +
  permission set, key in an app-owned Keychain item) is a follow-up
  alongside auxiliary-file hashing; both bind "consent" to "what
  actually executes".
- The Maker never silently grants: generated manifests suggest the minimum set;
  elevating requires the user to tick it (or edit the JSON).
- **Why `clipboard.read` isn't gated:** the consent gate is for ambient
  capabilities where declaration isn't enough (`shell`, `paste`); a
  clipboard read is a declared capability the permission badge already
  surfaces. The known gap is the *pairing*: `clipboard.read` + `network`
  (`invoque.fetch`) is an ungated exfiltration path — the same class of
  hole as the `open` ambient-egress fix, but for a declared module. Whether
  `network`, `clipboard.read`, or the pair should join `risky` is a
  manifest-schema decision deferred to a follow-up rather than grown into
  the consent PR.

---

## 5. Permissions, Signing & Distribution

- **No TCC permission required for core.** Carbon `RegisterEventHotKey`
  (Zap's `CarbonHotkey`, reused) summons the panel with zero grants.
- **Accessibility** is needed only by `paste` commands (simulated keystrokes
  via `CGEvent`) — prompt lazily on first use, like Zap's `PermissionsView`.
- `LSUIElement = true`; launch at login via `SMAppService`.
- Hardened Runtime + `com.apple.security.cs.allow-jit` (JSC fast path;
  interpreter is the fallback). Developer ID + notarization; **no sandbox**
  (generated code + optional AX make it impossible anyway — same conclusion
  as Zap).
- LLM API key in Keychain; never in the commands dir or UserDefaults.

---

## 6. The `make` Command

Built-in query prefix — `make <prompt>`/`mk <prompt>` — routed by
`PanelModel` like filter mode: while the prefix is present, `MakerView`
replaces the results list inline (no pushed view — the swap is the same
shape the filter list already uses).

```
make command to format clipboard json
  → MakerModel.start(prompt)            single-shot LLMClient.complete —
                                        no streaming in v1; a command is
                                        only usable once fully generated
  → GenerationParser.parse              `--- command.json ---`/`--- main.js ---`
                                        delimiter blocks (what the prompt
                                        demands), with markdown ```json/
                                        ```js fences accepted as fallback;
                                        `lang:name`/`lang name` on a fence
                                        names extra files. Strict: exactly
                                        one manifest + one entry.
  → GeneratedCommandValidator           manifest decodes + validateStructure
                                        (no dir needed) · JS compiles via
                                        `new Function` — parsed, never run ·
                                        invoque.*↔permissions cross-check on
                                        comment/string/template-masked source
  → Maker view                          draft summary (title, mode,
                                        permissions, files) + issues; an
                                        expanded, selectable source viewer
                                        exposes every generated file before
                                        Save; Test runs the draft in a temp
                                        staging dir via CommandRunner —
                                        explicit, never automatic
  → feedback loop                       "broke on empty clipboard" → appended
                                        to the transcript → regenerate
  → save                                CommandWriter writes the folder;
                                        snapshots prior revision into
                                        history/; store.scan() makes it live
```

- `edit command <name>` enters the same flow seeded with existing files —
  **not yet implemented** (the writer's history/ snapshotting supports it).
- System prompt (`Maker/SystemPrompt.swift`): compact `invoque.d.ts` of the
  API, manifest schema, one worked example, and rules (no sync loops, declare
  permissions honestly, prefer `action` unless listing). Kept in sync with
  `InvoqueBridge`.
- Provider settings: base URL (OpenAI-compatible → OpenAI/OpenRouter/Ollama/
  LM Studio), model, API key (Keychain), Anthropic mode toggle — implemented
  (`/v1/messages` + `x-api-key` + `anthropic-version`). Test button in
  Settings hits `/models` (`/v1/models` for Anthropic).
- Provenance: `generated.prompt`/`model`/`revision` in the manifest; every
  accepted revision snapshots the old files into `history/<timestamp>/` —
  rollback is a file copy the user can do by hand, and the Maker can offer
  "revert to revision N" (not yet implemented).

---

## 7. Settings Window

SwiftUI window from the menu-bar item (Zap's pattern):

1. **General** — hotkey recorder (default ⌥Space), launch at login, panel
   position basics.
2. **Appearance** — the theming controls from §3 (material, colors, selection,
   adaptive accent, layout, decoration, CRT, presets with import/export) plus
   a live preview of the real `PanelView` fed by an inert sample `PanelModel`.
3. **Commands** — list of loaded commands (title, mode, permissions, origin),
   commands directories (add/remove, reveal in Finder), per-command
   enable/disable.
4. **AI** — provider, base URL, model, API key, test-connection.
5. **Permissions** — Accessibility status (needed only for `paste` commands) +
   System Settings deep links.
6. **About/Updates** — GitHub-release updater ported from Zap `Updates/`:
   `UpdateChecker` checks `L-K-M/Invoque` releases on launch + daily (24 h
   throttle, state in UserDefaults under `UpdateChecker.L-K-M.Invoque.*`),
   and its alert offers Download (asset → `~/Downloads`, revealed in
   Finder), Remind Me Later, or Skip This Version (compared semantically —
   a `v1.3.0`→`1.3.0` retag still counts as skipped). A menu-bar agent is
   almost never active, so a background check that finds a newer release
   *queues* it instead of popping a focus-stealing modal: an "Update
   Available: ⟨tag⟩" item appears on the status menu, and the alert
   presents on the next real activation or that item's click. Settings
   shows the automatic-check toggle, a "Check Now" button and the
   last-check date; the status menu has "Check for Updates…". A ported
   `ActivationHandoff` + `AppActivator` (activation-only subset of Zap's
   `WindowEnumerator`) brings the agent forward for alerts and returns
   focus to the previous app — also wired into the Settings window
   lifetime.

Menu: *Open Invoque* · *Update Available…* (when a background check has one
queued) · *Settings…* · *Commands folder* · *Check for Updates…* · *Quit*.
(*Commands folder* is documented intent — the item isn't implemented yet.)

---

## 8. Persistence

- `UserDefaults`: hotkey, appearance, usage/frecency counts (small Codable
  dict), settings.
- Commands + their `data/`/`history/` live on disk by design — the files *are*
  the database.
- Per-command `storage` module → JSON file under `<command>/data/storage.json`.
- No CoreData, no SQLite.

---

## 9. Project Structure

Mirroring Zap (Xcode 16 file-synchronized groups — no pbxproj edits):

```
Invoque/
├── Invoque.xcodeproj
├── Invoque/
│   ├── InvoqueApp.swift        # @main (or manual NSApplication bootstrap —
│   │                           #   evaluate; Zap uses App+delegate)
│   ├── AppDelegate.swift
│   ├── AppActivator.swift      # activation subset of Zap's WindowEnumerator
│   ├── ActivationHandoff.swift # focus handoff after alerts/Settings (Zap)
│   ├── Hotkey/
│   │   ├── CarbonHotkey.swift           # from Zap
│   │   └── HotkeyRecorder.swift         # settings UI
│   ├── Panel/
│   │   ├── LauncherPanel.swift          # NSPanel .nonactivatingPanel
│   │   ├── PanelController.swift        # show/hide/toggle, cursor-screen
│   │   ├── PanelView.swift              # SwiftUI card: field + list + footer
│   │   ├── PanelBackground.swift        # material: Liquid Glass/blur/fill/gradient
│   │   ├── AdaptiveAccent.swift         # icon-dominant-color selection tint
│   │   └── PanelDecoration/CRT/BoingBall # retro flourishes (from Zap)
│   ├── Icons/
│   │   └── InvoqueIcons.swift           # PictKit seam: resolver + watcher
│   ├── Search/
│   │   ├── ItemSource.swift             # protocol + Item model
│   │   ├── FuzzyMatcher.swift           # pure, unit-tested
│   │   ├── Frecency.swift
│   │   ├── FileSearch.swift             # find/f/search mode: Spotlight-free dir walk, scoped roots
│   │   └── Sources/                     # Apps, Commands, Calculator, System,
│   │                                    #   Path (typed file paths), Web
│   ├── Commands/
│   │   ├── CommandManifest.swift        # Codable + validation
│   │   ├── CommandStore.swift           # scan roots, FS-watch, reload
│   │   ├── CommandPermissionGrants.swift # first-run consent records
│   │   ├── JSRuntime.swift              # JSContext lifecycle, eval, errors
│   │   ├── InvoqueBridge.swift          # invoque.* assembly per permissions
│   │   └── Modules/                     # Clipboard, Fetch, FS, Shell, …
│   ├── Maker/
│   │   ├── MakerModel.swift             # idle→generating→draft→(testing)?→
│   │   │                                #   readyToSave→saved state machine
│   │   ├── MakerView.swift              # in-panel SwiftUI (inline swap)
│   │   ├── MakerSettings.swift          # provider/baseURL/model (UserDefaults)
│   │   ├── Keychain.swift               # API key — SecItem wrapper
│   │   ├── LLMClient.swift              # single-shot, OpenAI + Anthropic
│   │   ├── GenerationParser.swift       # delimiter/fenced blocks → files
│   │   ├── GeneratedCommandValidator.swift  # manifest+JS+permission checks
│   │   ├── CommandWriter.swift          # save + history/ snapshots
│   │   └── SystemPrompt.swift           # invoque.d.ts + schema + rules
│   ├── Settings/                        # same pattern as Zap (+ AngleDial)
│   ├── Updates/                         # copied from Zap (GitHub releases)
│   ├── Model/                           # Preferences + theming value types:
│   │   ├── EntryRules.swift             #   pin/block access — closures over Prefs
│   │   ├── SearchEngine.swift           #   the web fallback's engine picker values
│   │   ├── Preferences.swift            #   UserDefaults, validated on load
│   │   ├── AppearancePreset.swift       #   shareable themes + Zap/Jetty import
│   │   ├── PanelMaterial.swift          #   background material enum
│   │   ├── PanelTypeface.swift          #   typeface choice: system designs + installed families
│   │   ├── RGBA8.swift · ColorHex.swift #   #RRGGBB[AA] storage + color bridge
│   │   └── DecorationStyle/Position · AccessibilityDisplaySettings  # (Zap)
│   └── Resources/Assets.xcassets
├── InvoqueTests/                        # matcher, manifest, parser, runtime
├── scripts/{build.sh,release.sh,make-app-icon.py}   # lkm stubs; icon2.png → appiconset + accent + StatusIcon
├── .github/workflows/{ci,release}.yml   # hardened per family conventions
├── AGENTS.md · PLAN.md · RESEARCH.md · README.md · LICENSE
└── .gitignore                           # Zap's
```

---

## 10. Milestones

1. **Skeleton** — agent app, Carbon hotkey, nonactivating panel, typeable
   field, Esc/deactivate dismissal, menu-bar item.
2. **Search core** — `ItemSource` + matcher + frecency; Apps, System,
   Calculator, Web sources.
3. **Command runtime** — manifest loading, file watching, `js` runtime,
   `action` mode, permission-gated bridge (storage/clipboard/notify/open/fetch).
4. **Filter mode** — per-keystroke commands with debounce + stale-drop.
5. **Maker** — LLM config, fenced-block generation, validation, in-panel test
   run, feedback/diff loop, save with `history/` snapshots.
6. **Hardening** — `shell`/`paste`/`files`/`apps` modules + confirmation UX,
   frecency tuning, error surfaces.
7. **Release machinery** — lkm-build/lkm-release stubs, CI + release workflows,
   Developer ID + notarization, updater.

Later: `exec` runtime, `view` mode (data-declared UI), clipboard history /
snippets / window switching sources, Raycast script-command import (the comment
metadata maps onto our manifest).

---

## 11. Open Questions

- **Panel bootstrap:** SwiftUI `App` vs manual `NSApplication` — kloudsamurai's
  launcher argues manual bootstrap fits a summonable agent better; Zap uses
  `App` + delegate successfully. Decide in milestone 1; default to Zap's way.
- **Double-⌘ or ⌥Space?** ⌥Space default (Carbon, zero-permission). A
  double-tap-⌘ trigger needs an event tap — that reintroduces mandatory AX;
  keep it out of v1.
- **Filter-mode writes:** should filter scripts be allowed `clipboard.write`/
  `shell`? Probably restrict filters to read-only modules — a keystroke-driven
  side effect is a footgun. Decide when implementing §4.2.
- **SwiftPM vs xcodeproj:** nova-launcher shows a pure-SwiftPM app is viable,
  but the family template (and notarization flow in `lkm-build`/`lkm-release`)
  is xcodeproj-based. Stay on xcodeproj.
