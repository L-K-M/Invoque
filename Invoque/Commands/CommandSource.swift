import Foundation

/// Exposes the loaded commands as search items: one row per command, matched
/// by title and manifest keywords. Also resolves the `<keyword> …` query
/// prefix that routes into a filter-mode command's live list.
///
/// `CommandStore` owns scanning and watching; this source only reads
/// `store.commands`, which is cheap enough to serve per keystroke.
/// `Sendable` is asserted: the sole mutable member (`onReload`) is
/// main-queue confined by usage — set once during model wiring.
final class CommandSource: ItemSource, @unchecked Sendable {

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
        // `<trigger> <rest>` binds `rest` as an action command's args —
        // the same routing rule filter mode already uses (`rest` arrives
        // as args[0], the whole remainder). The trigger is the command's
        // name or first keyword, and the rest trims like the file-search
        // text. The compare is case-insensitive: unlike filter routing —
        // where the trigger consumes input — an action row still runs
        // when the case misses, so dropping the args would silently
        // change what the command does.
        let trigger: String?
        let args: [String]
        if let spaceIndex = query.firstIndex(of: " ") {
            trigger = String(query[..<spaceIndex])
            let rest = String(query[spaceIndex...].dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            args = rest.isEmpty ? [] : [rest]
        } else {
            trigger = nil
            args = []
        }
        return store.commands.map { command in
            let manifest = command.manifest
            let action: Item.Action
            if manifest.mode == .filter {
                // First keyword is the filter trigger; a keywordless
                // filter command falls back to its own name.
                action = .enterFilter(
                    keyword: manifest.keywords.first ?? manifest.name,
                    commandName: manifest.name)
            } else {
                let bound = trigger.map { word in
                    [manifest.name, manifest.keywords.first]
                        .compactMap { $0 }
                        .contains {
                            $0.caseInsensitiveCompare(word) == .orderedSame
                        }
                } ?? false
                action = .runCommand(manifest.name, bound ? args : [])
            }
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
