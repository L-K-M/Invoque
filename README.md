# Invoque.app

A keyboard-first macOS launcher in the Raycast/Alfred tradition — summon a
panel on a global hotkey, type, hit ⏎. Custom commands are **plain files on
disk** (a `command.json` manifest plus a `main.js` script on JavaScriptCore),
and the built-in `make` command asks a configured LLM to write, test, and
refine new commands without leaving the panel.

## What it does

- **Launch** apps and commands, fuzzy-matched and ranked — exact prefix
  beats infix beats fuzzy, shorter matches win, and results stay stable
  while you keep typing.
- **Calculate** inline (`2+2*3`, unit-free — the answer row pins first, behind only a typed path).
- **Find files** without Spotlight: `find notes`, `f notes`, or
  `search notes` walks the disk directly — hidden dirs and dependency
  trees pruned, dependency build folders too. Matches stream in as the
  walk finds them. What it walks is yours to choose (Settings → General
  → File Search): your home folder by default, plus the whole startup
  disk and external drives if you enable them. ⏎ opens, ⌘⏎ reveals in
  Finder — and ⏎ *while it's still searching* hands the scan to its own
  window, where it keeps streaming and the results stay actionable.
- **Paste a path** — `/tmp/build.log` or `~/Documents` — and the row is the
  path itself: ⏎ opens folders, reveals files (⌘⏎ inverts it). A file is
  never executed on a paste.
- **Search the web** as the always-last fallback, against your configured
  engine — DuckDuckGo, Google, Bing, Kagi, Brave, Startpage, Qwant,
  Ecosia, or Mojeek (Settings → General).
- **Pin and block** entries: ⌘P (or right-click → Pin) keeps an app,
  command, action or file hit above other matches whenever it matches;
  ⌘B blocks it outright. Manage the lists in Settings → General.
- **System actions** — lock, sleep, restart, empty trash…
- **Make commands** with natural language: `make command to format
  clipboard json` generates the manifest and script, runs it on real input
  inside the panel, takes feedback, regenerates, and saves — with history
  and rollback. Generated code declares permissions (`clipboard`,
  `shell`, `network`…); risky ones ask for consent on first run.
- **Look like yourself**: material/transparency, highlight, corner
  radii, retro corner decorations and CRT scanlines —
  captured as shareable theme presets (Classic, Summon, Graphite, ZX
  Night, Vaporwave, Synthwave, Memphis, Amiga), with JSON import/export
  that also reads Zap and Jetty theme files. Icons resolve through the
  shared PictKit store — the same ladder Zap, Jetty, and Top Drawer draw
  from.

## The commands

Commands live under `~/.config/invoque/commands/<name>/` as readable files
— `command.json` (manifest: title, keyword, mode, permissions) plus
`main.js`. Edit by hand, version with git, share by copying the folder.
Filter-mode commands take over the result list; action-mode commands run
and hand back items, a title, or nothing.

## Building

Requires macOS 13+ and Xcode 16+ (the project uses file-system–synchronized
groups — drop a file in, it's compiled). `scripts/build.sh` produces
`Invoque.app`; tests via `xcodebuild -scheme Invoque test`. CI runs the
suite plus an icon-drift check: `scripts/make-app-icon.py` renders the
appiconset and the menu-bar StatusIcon mark from `media-sources/icon2.png`.

The design and milestones live in [`PLAN.md`](PLAN.md); the research that
led here (prior art, engine evaluation, feasibility) in
[`RESEARCH.md`](RESEARCH.md). Conventions for agents in `AGENTS.md`.

Sibling projects: **[Zap](https://github.com/L-K-M/Zap)** (app switcher),
**[Jetty](https://github.com/L-K-M/Jetty)** (Dock replacement),
**[Top Drawer](https://github.com/L-K-M/TopDrawer)** (edge-tab launcher).
