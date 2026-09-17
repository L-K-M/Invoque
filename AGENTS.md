# AGENTS.md

Guidance for AI coding agents working in the **Invoque** repository.

## What Invoque Is

Invoque is a keyboard-first macOS launcher (Raycast/Alfred class). Custom
commands are plain files — a `command.json` manifest plus a `main.js` script on
JavaScriptCore — and a built-in `make` command generates new commands with a
configured LLM. `RESEARCH.md` holds the findings; `PLAN.md` holds the design and
milestones. **Read PLAN.md before writing code.**

## Status

Early implementation: the Xcode project shell exists (agent app, status item,
Settings window, tests, CI). Panel, search, command runtime, and the Maker land
per `PLAN.md` milestones. Mirror **[Zap](https://github.com/L-K-M/Zap)** — same
maintainer, same conventions. `Zap/AGENTS.md` and `Zap/PLAN.md` are the template
this project follows.

## Tech Stack

- **Language:** Swift (latest stable).
- **UI:** SwiftUI for panel content and Settings; AppKit for windowing —
  `NSPanel` with `.nonactivatingPanel`, `NSStatusItem`.
- **Scripting:** `JavaScriptCore` (system framework — the sanctioned way to keep
  zero third-party dependencies). Commands declare permissions; undeclared
  `invoque.*` modules are not injected into their `JSContext`.
- **System APIs:** Carbon `RegisterEventHotKey` (no TCC permission needed),
  `NSWorkspace`, `NSPasteboard`, `SMAppService`, Keychain for the LLM API key.
- **Persistence:** `UserDefaults` for settings; commands and their `data/`/
  `history/` live as files under `~/.config/invoque/commands/` — the files are
  the database.
- **Min target:** macOS 13 or newer (revisit to match Zap when starting).
- **App type:** menu-bar agent (`LSUIElement = true`, no Dock icon).
- **Distribution:** Developer ID + notarization; no App Store, no sandbox.
  Hardened Runtime + `com.apple.security.cs.allow-jit` for the JSC fast path.

## Build & Run

Once the project exists, follow the L-K-M family conventions (same as Zap):

- `scripts/build.sh` and `scripts/release.sh` are thin stubs over the shared
  `lkm-build`/`lkm-release` engines (https://github.com/L-K-M/release-tool).
- `xcodebuild -project Invoque.xcodeproj -scheme Invoque` for direct builds;
  tests with `-destination 'platform=macOS' test`.
- Xcode 16 file-system–synchronized groups — new files under `Invoque/` are
  picked up automatically.

## Conventions

- Follow standard Swift API Design Guidelines; one type per file, file name
  matches the type, `// MARK:` sections.
- Keep the search hot path allocation-light — matching runs per keystroke.
- Don't add heavy dependencies; prefer system frameworks.
- Generated-command code is untrusted input: everything reachable from JS goes
  through the permission gate; `shell` and `paste` require first-run user
  confirmation. Never run generated code on first save — first run is
  user-triggered.
- The `invoque.*` JS API is a public contract: changes to it are a design
  decision — update `PLAN.md`, the manifest schema, and the Maker's system
  prompt together.
- Accessibility permission is only needed for `paste`-style commands; handle
  the not-granted case gracefully and prompt lazily.
- Unit-test pure logic: the fuzzy matcher, manifest validation, the generation
  parser, permission cross-checks. Panel/window behavior needs a real GUI
  session — verify manually.

## Do / Don't

- **Do** update `PLAN.md` when the design changes.
- **Do** keep commands inspectable: no hidden state — anything the app knows
  about a command lives in its directory as readable files.
- **Don't** put secrets (API keys, tokens) anywhere but Keychain — never in
  `command.json`, `UserDefaults`, or logs.
- **Don't** give filter-mode commands side-effectful modules by default.
- **Don't** commit signing credentials or provisioning profiles.
