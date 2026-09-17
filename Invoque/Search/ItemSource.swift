import Foundation

/// A provider of search items: apps, commands, calculator results, system
/// actions, the web fallback. `SearchModel` gathers every source per
/// keystroke, so `items(matching:)` must be cheap: cached sources answer from
/// memory, while query-driven sources (calculator, web) compute without I/O.
protocol ItemSource {
    /// Items relevant to `query`. Cached sources may ignore the query and
    /// return everything; `SearchModel` scores and filters.
    func items(matching query: String) -> [Item]

    /// Refreshes cached content. Called on launch and when the underlying
    /// data changes (app installs, command edits). Query-driven sources
    /// without a cache ignore it.
    func reload()
}

// MARK: Defaults

extension ItemSource {
    func reload() {}
}
