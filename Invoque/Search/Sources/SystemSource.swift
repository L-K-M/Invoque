import Foundation

/// The fixed macOS actions. No scan, no state: the same five items every
/// time, so the matcher and frecency do all the ranking work.
final class SystemSource: ItemSource {

    // MARK: ItemSource

    func items(matching query: String) -> [Item] {
        Item.SystemAction.allCases.map(Self.item(for:))
    }

    // MARK: Items

    /// One fixed item per action. Titles use the words people type ("lock",
    /// "shut down"); `matchText` adds the synonyms the title misses.
    private static func item(for action: Item.SystemAction) -> Item {
        switch action {
        case .lockScreen:
            return make(action: action, title: "Lock Screen", subtitle: "Lock your Mac (Ctrl-Cmd-Q)",
                        symbol: "lock.fill", keywords: "lock display secure screen saver")
        case .sleep:
            return make(action: action, title: "Sleep", subtitle: "Put your Mac to sleep",
                        symbol: "moon.fill", keywords: "sleep rest nap power save")
        case .restart:
            return make(action: action, title: "Restart", subtitle: "Restart your Mac",
                        symbol: "arrow.counterclockwise", keywords: "restart reboot boot")
        case .shutDown:
            return make(action: action, title: "Shut Down", subtitle: "Shut down your Mac",
                        symbol: "power", keywords: "shut down shutdown power off halt")
        case .emptyTrash:
            return make(action: action, title: "Empty Trash", subtitle: "Permanently delete items in your home Trash",
                        symbol: "trash.fill", keywords: "empty trash delete clear bin remove")
        }
    }

    private static func make(action: Item.SystemAction, title: String, subtitle: String, symbol: String, keywords: String) -> Item {
        Item(
            id: Item.systemIDPrefix + action.rawValue,
            title: title,
            subtitle: subtitle,
            icon: .symbol(symbol),
            action: .system(action),
            matchText: "\(title) \(keywords)"
        )
    }
}
