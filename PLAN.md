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
- Built-in sources: apps, commands, calculator, system actions, web-search
  fallback. (Files/clipboard history/snippets are candidates — pick by scope.)
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
`NSWorkspace` for app listing, `UserDefaults` for preferences. No third-party
dependencies. Targets macOS 13+ (revisit if Zap has since raised its floor).

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

### Search model
- `ItemSource` protocol: `func items(for query: String) -> [Item]` (sync,
  cached sources) and async `reload()` for dynamic ones.
- Sources v1: `AppSource` (NSWorkspace scan, LaunchServices apps), 
  `CommandSource` (from CommandStore), `CalculatorSource`, `SystemSource`
  (lock/sleep/restart/empty trash…), `WebSource` (fallback "Search for X").
- Fuzzy matcher: small fzf-style scorer (subsequence bonus, word-boundary
  bonus, recency/frecency weighting). Pure function — unit-test it. Zap's
  type-to-search matching is the local precedent.
- Ranking: base match score + frecency (persisted usage counts in
  UserDefaults/CoreData-free flat file) + source priorities (calculator
  exact-match > commands > apps > web fallback).

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
  | `apps` | `apps` | NSWorkspace query/launch |
  | `paste` | `paste` | simulate ⌘V — needs app-level AX grant |
  | `shell` | `shell` | `/bin/sh -c`; first-run confirmation sheet |

- Errors: `context.exceptionHandler` → surfaced in-panel and logged.
  Async contract: entry point is `export default async function`; a tight
  synchronous loop cannot be interrupted — on timeout the context is abandoned
  and its result discarded (documented limitation; the generator's system
  prompt forbids unbounded sync loops).
- Calculator and "eval JS" can reuse this engine — one runtime, three uses.

### 4.3 Permissions UX

- Declared in the manifest, visible on the command's detail line (small lock
  badge). First run of a `shell`/`paste` command shows a confirmation sheet
  explaining what it will do.
- The Maker never silently grants: generated manifests suggest the minimum set;
  elevating requires the user to tick it (or edit the JSON).

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
                                        permissions, files) + issues; Test
                                        button runs the draft in a temp
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
  `InvoqueBridge` — `paste`/`apps` are listed as not-yet-implemented.
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
   position/appearance basics.
2. **Commands** — list of loaded commands (title, mode, permissions, origin),
   commands directories (add/remove, reveal in Finder), per-command
   enable/disable.
3. **AI** — provider, base URL, model, API key, test-connection.
4. **Permissions** — Accessibility status (needed only for `paste` commands) +
   System Settings deep links.
5. **About/Updates** — GitHub-release updater copied from Zap `Updates/`.

Menu: *Open Invoque* · *Settings…* · *Commands folder* · *Quit*.

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
│   ├── Hotkey/
│   │   ├── CarbonHotkey.swift           # from Zap
│   │   └── HotkeyRecorder.swift         # settings UI
│   ├── Panel/
│   │   ├── LauncherPanel.swift          # NSPanel .nonactivatingPanel
│   │   ├── PanelController.swift        # show/hide/toggle, cursor-screen
│   │   ├── PanelView.swift              # SwiftUI card: field + list + footer
│   │   └── ResultRowView.swift
│   ├── Search/
│   │   ├── ItemSource.swift             # protocol + Item model
│   │   ├── FuzzyMatcher.swift           # pure, unit-tested
│   │   ├── Frecency.swift
│   │   └── Sources/                     # Apps, Commands, Calculator, System, Web
│   ├── Commands/
│   │   ├── CommandManifest.swift        # Codable + validation
│   │   ├── CommandStore.swift           # scan roots, FS-watch, reload
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
│   ├── Settings/                        # same pattern as Zap
│   ├── Updates/                         # copied from Zap (GitHub releases)
│   ├── Model/Preferences.swift
│   └── Resources/Assets.xcassets
├── InvoqueTests/                        # matcher, manifest, parser, runtime
├── scripts/{build.sh,release.sh}        # lkm-build/lkm-release stubs
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
