import AppKit
import PictKit

/// View model for the detached file-search window — the display face a
/// `FileSearchSession` gets after ⏎ hands it off from the launcher
/// panel (`PanelModel.submit` → `DetachedSearchWindowController`). The
/// session outlives the handoff: the walk keeps streaming and this model
/// only shapes and forwards, never re-walks the disk.
///
/// The window is a persistent results browser, not a transient launcher:
/// ⏎ performs the row's action and the window stays up; closing it
/// (esc/⌘W/close button) is what retires the session.
final class DetachedSearchModel: ObservableObject {

    /// The full typed query — "find hello.pdf" — shown as the window's
    /// title and header text.
    let query: String

    /// The session's rows after pin/block shaping — the display list.
    /// Sole-writer invariant: only `refresh` assigns `rows`, and it
    /// re-points `selection` in the same synchronous pass — there is no
    /// didSet backstop, so any new assignment site must own `selection`
    /// too (a didSet reset would instead publish a phantom top selection
    /// between the rows write and the re-point).
    @Published private(set) var rows: [ResultRow] = []
    @Published var selection = 0
    @Published private(set) var isPending: Bool

    /// Performs the picked row's action — the window stays open after
    /// it fires.
    var onSubmit: ((Item.Action) -> Void)?

    /// Shared-store icon lookup — the same contract `PanelModel` hands
    /// the panel view.
    var iconResolver: ((IconTarget) -> NSImage?)?

    private let session: FileSearchSession
    private let entryRules: EntryRules

    init(session: FileSearchSession, entryRules: EntryRules,
         iconResolver: ((IconTarget) -> NSImage?)?) {
        self.session = session
        self.query = session.query
        self.entryRules = entryRules
        self.iconResolver = iconResolver
        self.isPending = session.isPending
        session.onUpdate = { [weak self] in self?.refresh() }
        session.onFinish = { [weak self] in self?.refresh() }
        refresh()
    }

    /// The currently selected row, or `nil` when there are no results.
    var selectedRow: ResultRow? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// Re-shapes the session's snapshot: pending flips republish even
    /// when the rows themselves are unchanged. Selection tracks by row
    /// id so a streamed batch inserting above the picked row doesn't
    /// snap it back to the top — the `results` didSet resets first.
    private func refresh() {
        isPending = session.isPending
        let shaped = Array(shape(session.items.map(ResultRow.init))
            .prefix(SearchModel.maxResults))
        guard shaped != rows else { return }
        let selectedID = selectedRow?.id
        rows = shaped
        // Guard the write: `@Published` emits on every assignment, so an
        // unchanged re-point would still publish a phantom selection.
        let index = selectedID
            .flatMap { id in shaped.firstIndex(where: { $0.id == id }) } ?? 0
        if selection != index { selection = index }
    }

    /// `PanelModel.shapeFileRows`' twin — blocked ids drop, pinned lead,
    /// applied to the session's raw list.
    private func shape(_ rows: [ResultRow]) -> [ResultRow] {
        let live = rows.filter { !entryRules.isBlocked($0.id) }
        return live.filter { entryRules.isPinned($0.id) }
            + live.filter { !entryRules.isPinned($0.id) }
    }

    // MARK: Selection & actions

    /// Moves the selection by `delta` rows, wrapping at both ends.
    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let count = rows.count
        selection = ((selection + delta) % count + count) % count
    }

    /// Selects `row` directly — mouse taps land here.
    func select(_ row: ResultRow) {
        guard let index = rows.firstIndex(of: row) else { return }
        selection = index
    }

    /// Hands the selected row's action to `onSubmit`. `commandModifier`
    /// is the ⌘⏎ reveal swap `PanelModel.submit` performs: ⌘⏎ on a file
    /// or app reveals it in Finder instead of opening it. The window
    /// stays open either way.
    func submit(commandModifier: Bool = false) {
        guard let row = selectedRow else { return }
        if commandModifier {
            switch row.action {
            case .openFile(let url), .openApp(let url):
                onSubmit?(.revealInFinder(url))
                return
            default:
                break
            }
        }
        onSubmit?(row.action)
    }

    // MARK: Entry rules (pin / block)

    /// Whether `row` is a durable entry the user can pin or block.
    func canManage(_ row: ResultRow) -> Bool {
        Item.isManageableID(row.id)
    }

    func isPinned(_ row: ResultRow) -> Bool {
        entryRules.isPinned(row.id)
    }

    /// Toggles the pin on `row` (default: the selection); returns HUD
    /// text describing the change. The write also fires the shared
    /// `entryRulesChanged` notification — the local `refresh` keeps the
    /// window honest even though that hook belongs to the panel.
    @discardableResult
    func togglePin(on row: ResultRow? = nil) -> String? {
        guard let row = row ?? selectedRow, canManage(row) else { return nil }
        let pinned = entryRules.togglePin(row.id, row.title)
        refresh()
        return pinned ? "Pinned \(row.title)" : "Unpinned \(row.title)"
    }

    /// The `togglePin` twin for blocking — the row vanishes on the spot.
    @discardableResult
    func toggleBlock(on row: ResultRow? = nil) -> String? {
        guard let row = row ?? selectedRow, canManage(row) else { return nil }
        let blocked = entryRules.toggleBlock(row.id, row.title)
        refresh()
        return blocked ? "Blocked \(row.title)" : "Unblocked \(row.title)"
    }

    /// A pin/block made elsewhere (the panel, the Settings lists) — the
    /// controller forwards the shared `entryRulesChanged` hook here so
    /// the detached list re-shapes without touching the session.
    func refreshRules() {
        refresh()
    }

    /// The window is closing — retire the session. A finished session
    /// no-ops; a live walk cancels.
    func close() {
        session.onUpdate = nil
        session.onFinish = nil
        session.cancel()
    }
}
