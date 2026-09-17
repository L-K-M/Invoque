# Invoque.app

A keyboard-first macOS launcher in the Raycast/Alfred tradition — app search,
calculator, system actions — whose custom commands are **plain files on disk**
(a `command.json` manifest plus a `main.js` script running on JavaScriptCore)
and whose built-in `make` command asks a configured LLM to write, test, and
refine new commands without leaving the panel.

Type `make command to format clipboard json`, watch it write the manifest and
the script, run it on real input, tell it what's wrong, and keep the result —
the command is just two files you can read, diff, and edit by hand.

> **Status: pre-implementation.** This repo currently holds the research and
> the design — see [`RESEARCH.md`](RESEARCH.md) (prior art, engine evaluation,
> feasibility) and [`PLAN.md`](PLAN.md) (architecture, command format, the
> `make` flow, milestones).

Sibling projects: **[Zap](https://github.com/L-K-M/Zap)** (app switcher),
**[Jetty](https://github.com/L-K-M/Jetty)** (Dock replacement),
**[Top Drawer](https://github.com/L-K-M/TopDrawer)** (edge-tab launcher).
