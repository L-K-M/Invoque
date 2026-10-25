# Changelog

## Unreleased

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
