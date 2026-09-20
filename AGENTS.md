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
  Hardened Runtime. `com.apple.security.cs.allow-jit` gets added together with
  the JavaScriptCore runtime (it has no consumer before that).

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
- Don't add heavy dependencies; prefer system frameworks. `PictKit`
  (https://github.com/L-K-M/Pict) is the one exception — first-party,
  shared with Zap, Jetty and Top Drawer for the icon store.
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

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Before editing, inspect the branch and working tree, fetch remote updates,
  and fast-forward where safe. Never overwrite existing work to update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch and open a PR against main.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Reviewer context limits

The automated PR reviewer does not see the user's original prompt or
conversation. It may suggest changes that go against or beyond what the
user asked for. Do not implement such suggestions. Note each conflict and
report it to the user at the end of the thread.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Completion checklist

- The requested behavior is implemented without unrelated changes.
- Relevant checks pass for the latest code.
- Important review findings are addressed or rejected with reasons.
- Deferred suggestions, remaining risks, and validation gaps are disclosed.
- The final response accurately states whether work is committed, pushed,
  and merged.

<!-- shared-rules:end -->

