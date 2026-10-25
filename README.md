# Invoque.app

**Latest release:** v<!-- version -->0.2.0<!-- /version --> · [Download](https://github.com/L-K-M/Invoque/releases/latest)

The build is ad-hoc signed and not notarized. After moving **Invoque** to
Applications, run:

```bash
xattr -dr com.apple.quarantine "/Applications/Invoque.app"
```


> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

A keyboard-first macOS launcher in the Raycast/Alfred tradition — summon a
panel on a global hotkey, type, hit ⏎. Custom commands are **plain files on
disk** (a `command.json` manifest plus a `main.js` script on JavaScriptCore),
and the built-in `make` command asks a configured LLM to write, test, and
refine new commands without leaving the panel.

## What it does

- **Launch** apps and commands, fuzzy-matched and ranked — exact prefix
  beats infix beats fuzzy, shorter matches win, and results stay stable
  while you keep typing — the matched characters read bolder in each
  title. An empty panel already lists what you launch
  most — frecency top hits, ⏎ runs the top row.
- **Calculate** inline with bundled [Numbat](https://numbat.dev): `2+2*3`,
  `sqrt(9)`, `sin(pi/2)`, `2^10`, `30 km/h -> mph`, `5 inch + 2 ft -> cm`.
  Use `= speed_of_light` for a named constant. ⏎ copies the result, including
  units. Base conversions (`255`, `0xFF`, `0b1010`) remain immediate.
  Calculations run locally; currency exchange rates are not included.
- **Find files** without Spotlight: `find notes`, `f notes`, or
  `search notes` walks the disk directly — hidden dirs and dependency
  trees pruned, dependency build folders too. Matches stream in as the
  walk finds them. What it walks is yours to choose (Settings → General
  → File Search): your home folder by default, plus the whole startup
  disk and external drives if you enable them. ⏎ opens, ⌘⏎ reveals in
  Finder, including while searching. ⏎ *while it's still searching*
  hands the scan to its own window, where it keeps streaming and the
  results stay actionable.
- **Paste a path** — `/tmp/build.log` or `~/Documents` — and the row is the
  path itself: ⏎ opens folders, reveals files; ⌘⏎ always reveals. A file is
  never executed on a paste.
- **Recall queries** with ↑ — the panel remembers the last 50 queries
  you submitted; ↓ walks forward again, and typing exits the history.
- **Search the web** as the always-last fallback, against your configured
  engine — DuckDuckGo, Google, Bing, Kagi, Brave, Startpage, Qwant,
  Ecosia, or Mojeek (Settings → General). A query that *is* an http(s)
  URL opens directly instead; the search row stays beneath it.
- **Copy any row** with ⌘C — the path for files and apps, the address
  for URLs, the answer for calculations, the title for the rest.
- **Pin and block** entries: ⌘P (or right-click → Pin) keeps an app,
  command, action or file hit above other matches whenever it matches;
  ⌘B blocks it outright. Manage the lists in Settings → General.
- **Generate** instant values: `uuid`, `now` (UTC ISO 8601), `flip`,
  `roll` / `d20` / `d6` — ⏎ copies the fresh value.
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
`main.js`. Edit by hand, version with git, share by copying the folder —
⌘⏎ on a command row reveals its folder in Finder.
Filter-mode commands take over the result list; action-mode commands run
and hand back items, a title, or nothing.

## Building

Requires macOS 13+, Xcode 16+, and [rustup](https://rustup.rs). The project uses
file-system–synchronized groups: drop a file in, it's compiled. `scripts/build.sh` produces
`Invoque.app`; tests via `xcodebuild -scheme Invoque test`. CI runs the
suite plus an icon-drift check: `scripts/make-app-icon.py` renders the
appiconset and the menu-bar StatusIcon mark from `media-sources/icon2.png`.

Xcode's **Bundle Numbat** phase builds the pinned Rust helper for the app's
architectures and includes its dependency licenses. The first build downloads
the pinned toolchain and Cargo dependencies. End users need no Rust or Numbat
installation. Engine checks: `cd Numbat && cargo test --locked`.

Numbat syntax applies: `^` means exponentiation, `log`/`ln` mean natural log,
and `log10` means base-10 log. Incompatible dimensions and incomplete input
offer no calculator row.

The design and milestones live in [`PLAN.md`](PLAN.md); the research that
led here (prior art, engine evaluation, feasibility) in
[`RESEARCH.md`](RESEARCH.md). Conventions for agents in `AGENTS.md`.

Sibling projects: **[Zap](https://github.com/L-K-M/Zap)** (app switcher),
**[Jetty](https://github.com/L-K-M/Jetty)** (Dock replacement),
**[Top Drawer](https://github.com/L-K-M/TopDrawer)** (edge-tab launcher).

## License

Invoque's own code is released under the [Unlicense](LICENSE). The app bundles
Numbat, its Rust dependencies and the Rust standard library, which keep their
own licenses. Their notices ship in the app's `Contents/Resources` as
`Numbat-Licenses.txt` and `Rust-Licenses.html`. `Numbat/LICENSE-*` are
Numbat's license texts, not the wrapper's.
