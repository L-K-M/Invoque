# Changelog

## Unreleased

- A hotkey press that arrives just as its shortcut is changed or turned off no
  longer fires the old action (Keycap 0.1.1).
- When GitHub's rate limit stops a Check for Updates, the alert says when to
  try again instead of showing a bare HTTP 403 (Updraft 0.2.0).
- Software update checks now use the shared Updraft package. Downloads are
  verified against the release's file size and SHA-256 digest where one is
  published, and only GitHub-hosted assets are fetched; assets named for
  another operating system are no longer offered, and a failed download now
  explains itself and offers the release page. Version parsing is stricter,
  the release page opened is always this repository's GitHub page, the daily
  check no longer skips a day, and the unparseable-version alert says whether
  the installed version or the release tag could not be read.
- Panel theming is now shared with the family apps through Livery. The CRT
  overlay's strength scales from nothing at intensity 0 to the same look as
  before at full intensity, so settings in between look slightly fainter, and
  the gradient direction dial gains a focus ring, arrow-key control and 5°
  VoiceOver steps instead of 15°.
- Summon hotkeys now use the shared Keycap package. The recorder accepts the
  same shortcuts as before (including ⌘Space), and the Accessibility button
  falls back to the legacy System Settings pane if the current one cannot be
  opened.
- Bundle Numbat for scientific calculations and unit conversions. `log` now
  means natural log; use `log10` for base-10. Currency rates are not included.

- ⌘⏎ on a command row reveals the command's folder in Finder instead of
  running it — the same reveal gesture file and app rows already had.
- Fixed Safari (and other App-cryptex apps) missing from results. Since
  Ventura they are grafted into `/Applications` by name lookup only, so
  directory enumeration never listed them; the catalog now scans the
  cryptex's Applications directory directly.
- Earlier history lives in the commit log and any GitHub releases; future
  changes will be noted here.
