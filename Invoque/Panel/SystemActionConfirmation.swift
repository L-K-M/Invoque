import Foundation

/// Trusted copy for a consequential built-in action awaiting explicit approval.
struct SystemActionConfirmation: Equatable {
    let row: ResultRow
    let action: Item.SystemAction

    init?(row: ResultRow) {
        guard case .system(let action) = row.action,
              action.requiresConfirmation else { return nil }
        self.row = row
        self.action = action
    }

    var title: String {
        switch action {
        case .restart:
            return "Restart this Mac?"
        case .shutDown:
            return "Shut down this Mac?"
        case .emptyTrash:
            return "Empty Trash?"
        case .lockScreen, .sleep:
            return ""
        }
    }

    var detail: String {
        switch action {
        case .restart, .shutDown:
            return "Open apps may close and unsaved work can be lost."
        case .emptyTrash:
            return "This permanently deletes items in your home Trash. This cannot be undone."
        case .lockScreen, .sleep:
            return ""
        }
    }

    var confirmLabel: String {
        switch action {
        case .restart:
            return "Restart"
        case .shutDown:
            return "Shut Down"
        case .emptyTrash:
            return "Empty Trash"
        case .lockScreen, .sleep:
            return "Confirm"
        }
    }

    var symbolName: String {
        switch action {
        case .restart:
            return "arrow.clockwise"
        case .shutDown:
            return "power"
        case .emptyTrash:
            return "trash"
        case .lockScreen:
            return "lock.fill"
        case .sleep:
            return "moon.fill"
        }
    }
}
