import Foundation

/// Exposes the loaded commands as search items: one row per command, matched
/// by title and manifest keywords. Also resolves the `<keyword> …` query
/// prefix that routes into a filter-mode command's live list.
///
/// `CommandStore` owns scanning and watching; this source only reads
/// `store.commands`, which is cheap enough to serve per keystroke.
final class CommandSource: ItemSource {

    /// Fires on the main queue whenever the store's command set changes —
    /// the panel re-runs the open query so new/edited commands appear
    /// without a relaunch.
    var onReload: (() -> Void)?

    private let store: CommandStore

    /// `store` is retained; its `onChange` is claimed here — a second
    /// consumer would need a fan-out.
    init(store: CommandStore, autoReload: Bool = true) {
        self.store = store
        store.onChange = { [weak self] _ in
            self?.onReload?()
        }
        if autoReload {
            // Commands can appear between store creation and wiring (the
            // store's own watcher is the source of truth on changes).
            Task { await reload() }
        }
    }

    // MARK: ItemSource

    func items(matching query: String) -> [Item] {
        // Every command is a candidate; SearchModel's fuzzy matcher does the
        // narrowing against matchText (title + keywords).
        store.commands.map { command in
            let manifest = command.manifest
            let action: Item.Action = manifest.mode == .filter
                // First keyword is the filter trigger; a keywordless filter
                // command falls back to its own name as the trigger word.
                ? .enterFilter(keyword: manifest.keywords.first ?? manifest.name,
                               commandName: manifest.name)
                : .runCommand(manifest.name, [])
            return Item(
                id: Item.commandIDPrefix + manifest.name,
                title: manifest.title,
                subtitle: manifest.description ?? "Command",
                icon: .symbol(manifest.icon ?? "terminal"),
                action: action,
                // The name doubles as the fallback trigger word for
                // keywordless filters, so it must be matchable too.
                matchText: ([manifest.title] + manifest.keywords + [manifest.name])
                    .joined(separator: " ")
            )
        }
    }

    func reload() async {
        // scan() is synchronous disk I/O; keep it off the caller's thread —
        // same contract as AppSource's reload.
        let store = self.store
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                store.scan()
                continuation.resume()
            }
        }
    }

    // MARK: Filter routing

    /// The filter-mode command claiming `keyword`, if any. The first token
    /// of a query is looked up here; a hit switches the panel into that
    /// command's live list.
    ///
    /// An exact manifest `name` match wins over a `keywords.first` match on
    /// a different command — a name is a command's own identity, a keyword
    /// can collide. Only `keywords.first` routes (PLAN §3: the first entry
    /// is the trigger word); a keywordless command is claimed by its name,
    /// the same fallback `items(matching:)` uses for `.enterFilter`.
    func filterCommand(forKeyword keyword: String) -> Command? {
        let filters = store.commands.filter { $0.manifest.mode == .filter }
        return filters.first { $0.manifest.name == keyword }
            ?? filters.first { $0.manifest.keywords.first == keyword }
    }
}
