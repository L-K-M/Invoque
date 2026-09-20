import Foundation

/// Read/write access to the user's pinned and blocked result entries.
///
/// A pinned entry ranks above ordinary matches whenever it matches the
/// query, until the pinned band fills the result cap (overflow rejoins
/// ranked order — see `SearchModel`); a blocked entry never appears.
/// Only durable ids are entries — `Item.isManageableID` — so functional
/// pins (`path:`/`calc:`/`web:`) and ephemeral `filter:` rows can't be
/// managed.
///
/// The closures keep `SearchModel`/`PanelModel` free of `UserDefaults`:
/// `Preferences` backs them in production, the default instance manages
/// nothing (so unwired models see the feature as absent), and tests
/// stub them outright. Reads are live — a Settings change applies to the
/// next refresh, not the next launch.
struct EntryRules {

    var isPinned: (_ id: String) -> Bool = { _ in false }
    var isBlocked: (_ id: String) -> Bool = { _ in false }

    /// Toggle and persist; returns the new state. `title` rides along for
    /// the Settings list — bare ids (`app:com.apple.Safari`) read poorly.
    var togglePin: (_ id: String, _ title: String) -> Bool = { _, _ in false }
    var toggleBlock: (_ id: String, _ title: String) -> Bool = { _, _ in false }
}
