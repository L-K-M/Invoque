# Invoque — Research Findings

Research for a macOS launcher (Raycast/Alfred class) whose custom commands are
plain files — a JSON manifest plus a script — and which can write its own
commands through a built-in LLM-powered `make` command.

Status: pre-implementation. This document records what exists, what works, and
what was decided. `PLAN.md` holds the proposed design.

---

## 1. Prior Art

### 1.1 How existing launchers do custom commands

| Product | Command format | Runtime | Notes |
|---|---|---|---|
| **Raycast Script Commands** | One file; metadata in comment directives (`@raycast.title`, `@raycast.mode`, `schemaVersion`) | Subprocess — any shebang language | Indexed from user-added "Script Directories"; auto-reloads on edit. Modes: `silent`, `compact`, `fullOutput`, `inline`. `needsConfirmation` flag exists. ([manual](https://manual.raycast.com/script-commands), [repo](https://github.com/raycast/script-commands)) |
| **Raycast Extensions** | npm package; `package.json` manifest declaring commands with modes `view` / `no-view` / `menu-bar` | Node.js extension host; React+TS rendered natively | The `view` mode is Raycast's real power — custom UI — but it is a closed, heavyweight pipeline. `AI.ask()` is built into the API. ([docs](https://developers.raycast.com)) |
| **Alfred Workflows** | `info.plist` + arbitrary scripts | Subprocess — any language | Script Filters print `{"items":[{title,subtitle,arg,icon,mods,...}]}` on stdout; Alfred renders. Per-keystroke process spawn works fine in practice. ([docs](https://www.alfredapp.com/help/workflows/inputs/script-filter/json/)) |
| **Flow Launcher** | `plugin.json` manifest + entry file | JSON-RPC over stdin/stdout to plugin process (Python/JS/TS/exe); .NET plugins in-process | The manifest fields (ID, ActionKeyword, ExecuteFileName, IcoPath, Language) are a good template. ([docs](https://github.com/Flow-Launcher/docs)) |
| **uLauncher / Albert / Keypirinha** | Manifest + Python | In-process Python | Linux/Windows; less relevant. |
| **Hammerspoon** | `~/.hammerspoon/init.lua` | Embedded Lua | Proves Lua is a fine macOS automation language; its `hs.*` API surface is the model for an `invoque.*` API. |

**Takeaway:** two dominant models — *subprocess with stdio contract* (Alfred,
Flow, Raycast script commands) and *embedded interpreter with a native API*
(Raycast extensions, Hammerspoon). Invoque should embed (see §3), and can add a
subprocess escape hatch later.

### 1.2 Open-source macOS launchers worth studying

| Project | Stack | Relevance |
|---|---|---|
| [ospfranco/sol](https://github.com/ospfranco/sol) | React Native macOS + Swift native modules | Broadest feature list (clipboard, emoji, window mgmt, math, script runner). RN is heavier than Invoque wants, but its feature set and command list are a good checklist. |
| [suho/nova-launcher](https://github.com/suho/nova-launcher) | Pure SwiftPM, SwiftUI | Minimal pure-Swift launcher; shows an Xcode-project-free build is viable. |
| [ainto-labs/ainto-app](https://github.com/ainto-labs/ainto-app) | AppKit+SwiftUI shell over a Rust core via C ABI | Does frecency search, clipboard store, and AI commands in Rust. More moving parts than needed; the C ABI boundary is real overhead. |
| [SuperCmdLabs/SuperCmd](https://github.com/supercmdlabs/supercmd) | Electron + React, `@raycast/api` shim, Swift helpers | Raycast-extension compatibility is achievable, but Electron + 11 Swift helper binaries is exactly the sprawl to avoid. |
| [kloudsamurai/launcher](https://github.com/kloudsamurai/launcher) | AppKit/NSPanel + SwiftUI content | Documents the `NSApplication`-bootstrap + nonactivating-panel pattern cleanly. |
| **Zap** (this family) | Swift, AppKit+SwiftUI | Same maintainer, same conventions. `Hotkey/CarbonHotkey.swift`, `Updates/` (GitHub-release updater), and the overlay windowing code are directly reusable. |

### 1.3 LLM-generated commands — precedents

- **Raycast AI Commands** turn *prompts* into one-press commands (no code
  generation). **PromptLab** adds contextual placeholders and AppleScript action
  hooks. Both validate the "command authored from a sentence" UX; neither writes
  executable code. ([manual](https://manual.raycast.com/ai/ai-commands), [repo](https://github.com/skaplanofficial/raycast-promptlab))
- **Shellyeah** (Raycast extension) generates shell commands from natural
  language — the closest shipped precedent for generate-then-run. ([PR](https://github.com/raycast/extensions/pull/19262))
- The **generate → run → show result → take feedback → regenerate** loop is
  well-established by coding agents; the novel part here is only that the output
  artifact is a launcher command instead of a repo file.

No launcher currently does generate-to-disk commands as a first-class feature.
That is the differentiator, and it is feasible because the artifact is just two
plain files the user can inspect, diff, and edit.

---

## 2. App language and windowing

**Swift, AppKit for windowing, SwiftUI for content — same stack as Zap.**
Reasons:

- Launcher windowing needs AppKit fidelity: `NSPanel` with
  `.nonactivatingPanel` (keyboard input without activating the app — the
  Spotlight trick), `.statusBar`/`.screenSaver` window level, and
  `collectionBehavior` `canJoinAllSpaces`/`fullScreenAuxiliary` to float over
  other apps' full-screen Spaces. This is documented, well-trodden AppKit.
- `LSUIElement` agent app, `SMAppService` login item, `NSWorkspace` for app
  enumeration — all the same machinery Zap already uses.
- Rust cores (Ainto) and Electron shells (SuperCmd) buy nothing a launcher needs
  and cost an ABI/IPC boundary plus distribution weight.

**Permissions posture (better than Zap's):** a global hotkey via Carbon
`RegisterEventHotKey` (Zap's `CarbonHotkey`) needs **no** TCC permission.
Accessibility is only required for *intercepting* keys (`CGEventTap`) or
*simulating* input into other apps (paste-into-frontmost-app). So Invoque's core
needs zero grants; AX becomes a per-command capability (§4). Screen Recording is
never needed unless a window-thumbnail feature appears.

**Distribution:** Developer ID + notarization, no App Store (same as Zap — the
app holds optional AX and generated code can't run in the sandbox anyway).
Hardened Runtime on; add `com.apple.security.cs.allow-jit` only if the
JavaScriptCore JIT is wanted (§3.1).

---

## 3. Command language and engine

### 3.1 Recommendation: JavaScript on JavaScriptCore

`JavaScriptCore.framework` is a **system framework** — zero dependencies, which
matches the family rule ("don't add heavy dependencies; prefer system
frameworks"). Bridging is first-class: `JSContext`, `JSValue`, and the
`JSExport` protocol expose native objects/methods to JS declaratively.

Decisive properties for *generated* code:

- **No ambient authority.** A fresh `JSContext` has no `fetch`, `console`,
  `process`, `URL`, `TextEncoder`, `require` — nothing. Every capability is one
  we deliberately inject, which is exactly the sandboxing model untrusted
  generated code needs. (Confirmed empirically by the SwiftBash/SwiftJSCore
  project, which had to reimplement all of it.)
- **LLM fluency.** JS is the highest-fluency language for every code model —
  materially better codegen than Lua.
- **Errors and values bridge cleanly**; a per-command `JSContext` gives
  isolation between commands.
- **Cost:** sub-millisecond context creation vs. tens of ms for a `node`
  subprocess. (SwiftBash measured <1 ms cold start.)
- **JIT:** under Hardened Runtime, JSC falls back to its interpreter unless the
  `allow-jit` entitlement is set. For command-scale work (format JSON, call an
  API, move files) interpreter speed is irrelevant; add the entitlement anyway
  since it's a checkbox — it's the documented Apple approach.

Caveats to document honestly:

- `evaluateScript` doesn't throw; wire `context.exceptionHandler`.
- `JSContext` isn't thread-safe — run each command's context on a dedicated
  serial queue. A *tight synchronous loop* can't be interrupted cooperatively;
  filter-mode commands should be written async so a hung context can be
  abandoned (known limitation; the API should steer generated code to async).

### 3.2 Alternatives considered

| Option | Verdict |
|---|---|
| **Lua 5.4** via [tomsci/LuaSwift](https://github.com/tomsci/luaswift/) or [ChrisGVE/LuaSwift](https://github.com/ChrisGVE/LuaSwift) | Viable, sandboxable (strip `os`/`io`/`debug`/`load`), Hammerspoon precedent. But: third-party dep, raw `lua_State` footguns ("misusing the stack will crash your program"), and much weaker LLM codegen. Rejected for v1. |
| **Luau** | Best-in-class sandboxing story (`luaL_sandbox`, read-only globals, fuzzed, built for actively-malicious code at Roblox). Still a C++ dep + weak codegen + C API bridging. Keep on the radar only if commands ever become shareable/executed from strangers. |
| **Subprocess scripts** (Alfred model) | Great escape hatch — `runtime: "exec"` runs any shebang file, output JSON on stdout. Spawn cost (~10–50 ms) is acceptable for actions, marginal for per-keystroke filters. Add in a later phase; don't make it the primary model (depends on user-installed runtimes). |
| **Node/Deno/V8 embedded** | Massive binary/signing/notarization surface for zero benefit over JSC here. Rejected. |
| **Swift itself** (compile-on-save) | Seconds-scale compile latency kills the hot path. Rejected. |

### 3.3 Command format

A directory per command — inspectable, editable, git-able:

```
~/.config/invoque/commands/format-clipboard-json/
├── command.json      # manifest
├── main.js           # entry point
└── history/          # snapshot per LLM revision (rollback)
    └── 2026-09-17T1930/…
```

`command.json` (borrows freely from Flow's `plugin.json` + Raycast's metadata):

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
  "generated": {
    "prompt": "make command to format clipboard json",
    "model": "claude-sonnet-4-5",
    "revision": 2
  }
}
```

- `mode`: `action` (run once, optional HUD output) or `filter` (query in →
  items JSON out, re-run per keystroke with debounce). A `view` mode
  (script-driven rich UI, the Raycast-extension model) is a later decision —
  likely a JSON-declared list/detail spec rather than embedded React.
- `runtime`: `js` (embedded JSC) now; `exec` (shebang subprocess, Alfred-style)
  later.
- `permissions` gate the injected API surface; unlisted modules are `undefined`
  in the context.
- `generated` records provenance: original prompt, model, revision count —
  makes hand-edited vs LLM-authored commands greppable.

The `invoque.*` API (v1 surface, all capability-gated):

```js
export default async function run(args, ctx) {
  const raw = await invoque.clipboard.read();          // clipboard.read
  const pretty = JSON.stringify(JSON.parse(raw), null, args.indent ?? 2);
  await invoque.clipboard.write(pretty);               // clipboard.write
  return { title: "Formatted JSON copied" };           // → HUD
}
```

Proposed modules: `clipboard`, `notify`, `open` (URL/file), `fetch` (network),
`storage` (per-command key-value, always allowed), `fs` (scoped — command's own
`data/` dir plus user-picked paths), `shell` (exec — highest risk, confirm on
first run), `paste` (simulate ⌘V — requires the app's AX grant), `apps`
(NSWorkspace query/launch), `args`, `log`. Filter mode returns `{items: [...]}`
in Alfred's shape.

**Commands directory:** default `~/.config/invoque/commands/` (dotfile/git
friendly — a user can symlink it into a repo to sync commands between machines).
Allow extra directories à la Raycast Script Directories. Watch with
`DispatchSource` FS events; hot-reload manifests on save.

---

## 4. The `make` command (LLM generation loop)

Flow:

1. **Trigger.** A built-in command matched by a `make `/`mk ` prefix; everything
   after it is the spec: `make command to format clipboard json`.
2. **Generate.** The configured LLM produces the two artifacts. For provider
   portability (any OpenAI-compatible endpoint, Anthropic, local via
   Ollama/LM Studio), prompt for fenced blocks — `--- command.json ---`,
   `--- main.js ---` — and parse, rather than relying on a vendor's
   tool-calling/structured-output schema. The system prompt carries a compact
   `.d.ts` of the `invoque.*` API, the manifest schema, and one worked example.
3. **Validate before showing.** Manifest parses + schema-checks; `main.js`
   parses by evaluating once in a throwaway context; declared permissions are
   sanity-checked against API usage (warn if code calls a module it didn't
   declare).
4. **Test in place.** A Maker view (dedicated SwiftUI pushed onto the panel —
   not implemented through the command runtime) runs the draft in a real but
   disposable context, shows result/stdout/errors, and a feedback box:
   *"it broke on empty clipboard"* → the transcript + failure output goes back
   to the model → regenerate → show a diff → accept or discard.
5. **Save.** Writes the folder, snapshotting any prior version into `history/`.
   Hot-reload picks it up immediately; the command is searchable at once.
6. **Iterate later.** `edit command <name>` re-opens the same flow seeded with
   the existing files — the manifest's `generated.revision` counter and the
   `history/` snapshots give rollback and provenance.

Provider config (Settings → AI): base URL (OpenAI-compatible covers OpenAI,
OpenRouter, Ollama, LM Studio), model name, API key in Keychain. Ainto and
Shellyeah both went the OpenAI-key route; key-in-Keychain is standard.

### Safety model

- JSC gives memory safety and no ambient capabilities; risk concentrates in the
  bridge we build. `shell` is the only true escape hatch → always shows a
  first-run confirmation (Raycast's `needsConfirmation` idea) and is excluded
  from the LLM's default permission suggestions.
- Generated code is always *shown* before save (the whole point of plain files);
  diffs on regeneration. Nothing auto-executes on first save — first run is
  user-triggered.
- A generated command runs with the app's privileges. The honest mitigation is
  capability-gating, review-before-save, and `history/` rollback — not
  sandboxing, which the app can't use anyway (hardened runtime + Developer ID
  distribution).

---

## 5. Feasibility assessment

- **Overall: feasible as a Swift/Xcode app matching the Zap template.** No novel
  systems work — every hard piece (nonactivating panel, Carbon hotkey,
  JSExport bridging, FS watching, LLM streaming) has a working public precedent
  or reusable family code.
- **Latency budget:** panel show <50 ms (NSPanel + cached index); JSC eval ~1 ms
  per keystroke — comfortably inside the filter-mode envelope. LLM generation is
  seconds, but it lives in the Maker view, never the hot path.
- **Riskiest piece is UX, not tech:** the generate→test→feedback loop has to
  feel as fast as Alfred or users won't bother. Keep the Maker view inside the
  panel (no separate window), stream the generation, and make
  *run-the-draft-with-real-input* one keystroke.
- **Known limitations to accept:** uninterruptible tight loops in JSC;
  permissions are advisory (a determined script can obfuscate); LLM codegen
  quality varies with model — mitigate with a strict API surface and good
  few-shot prompting.
- **Reuse from Zap:** `CarbonHotkey`, `AccessibilityAuthorizer` (for the
  optional paste feature), the GitHub-release `Updates/` module wholesale,
  `SemanticVersion`, build/release script stubs, CI/release workflows,
  `LSUIElement` agent-app setup, settings-window pattern.

---

## References

- Raycast: [Script Commands manual](https://manual.raycast.com/script-commands) · [script-commands repo](https://github.com/raycast/script-commands) · [AI Commands](https://manual.raycast.com/ai/ai-commands) · [AI API](https://developers.raycast.com/api-reference/ai)
- Alfred: [Script Filter JSON](https://www.alfredapp.com/help/workflows/inputs/script-filter/json/)
- Flow Launcher: [plugin.json](https://github.com/Flow-Launcher/docs/blob/main/plugin.json.md) · [JSON-RPC](https://github.com/Flow-Launcher/docs/blob/main/json-rpc.md)
- JavaScriptCore: [JSExport.h](https://github.com/WebKit/webkit/blob/master/Source/JavaScriptCore/API/JSExport.h) · [allow-jit entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.cs.allow-jit) · [NSHipster JSC](https://nshipster.com/javascriptcore/) · [SwiftBash JSC executor](https://github.com/Cocoanetics/SwiftBash/blob/main/Docs/SwiftJS.md)
- Lua: [tomsci/LuaSwift](https://github.com/tomsci/luaswift/) · [ChrisGVE/LuaSwift](https://github.com/ChrisGVE/LuaSwift) · [Luau sandboxing](https://luau.org/sandbox/)
- Panel: [Whid floating panel](https://whid.eu/blog/whid-the-origin/chapter-6-creating-a-spotlight-like-floating-panel-in-swift/) · [Apple forums: overlay above fullscreen](https://developer.apple.com/forums/thread/826308) · [philz on nonactivatingPanel](https://philz.blog/nspanel-nonactivating-style-mask-flag/)
- Launchers: [sol](https://github.com/ospfranco/sol) · [nova-launcher](https://github.com/suho/nova-launcher) · [ainto](https://github.com/ainto-labs/ainto-app) · [SuperCmd](https://github.com/supercmdlabs/supercmd) · [kloudsamurai/launcher](https://github.com/kloudsamurai/launcher)
