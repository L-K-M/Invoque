import Foundation

/// One selectable row in the launcher's results list: the display fields of
/// an `Item` plus the action picking it performs. The view never sees `Item`
/// itself — rows are the panel's presentation shape.
struct ResultRow: Identifiable, Equatable {

    let id: String
    let title: String
    let subtitle: String
    let icon: Item.Icon
    let action: Item.Action

    init(item: Item) {
        self.init(id: item.id, title: item.title, subtitle: item.subtitle,
                  icon: item.icon, action: item.action)
    }

    /// Direct construction for rows that aren't `Item`s — filter-mode
    /// results and error rows.
    init(id: String, title: String, subtitle: String,
         icon: Item.Icon, action: Item.Action) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.action = action
    }
}

/// View model for the launcher panel: query, results, and the selection
/// within them. Foundation-only so the selection logic stays unit-testable.
///
/// The search is synchronous: sources serve cached data (`AppSource` holds
/// an in-memory scan; calculator/system/web compute in microseconds), so a
/// `results(for:)` per keystroke stays on the main thread by design.
final class PanelModel: ObservableObject {

    /// Receives the selected row when the user presses ⏎ — `nil` when there
    /// are no results. The panel's owner (PanelController) performs the
    /// row's action.
    var onSubmit: ((ResultRow?) -> Void)?

    /// The search backend. Assigning re-runs the open query so late wiring
    /// (sources assembled after the model exists) still fills the list.
    var searchModel: SearchModel? {
        didSet { refreshResults() }
    }

    /// Resolves the first token of a query to a filter-mode command — the
    /// `<keyword> rest` routing from PLAN §3. Wired from `CommandSource`;
    /// `nil` in tests that don't exercise filters.
    var filterLookup: ((String) -> Command?)? {
        didSet { refreshResults() }
    }

    /// Resolves a command by manifest name — used when a picked `.enterFilter`
    /// row pins the session to that exact command, so a shared trigger word
    /// can't reroute the query into a different command's list.
    var commandLookup: ((String) -> Command?)?

    /// Runs filter-mode commands. Injected for the same reason as
    /// `filterLookup`; a real `CommandRunner` works in tests too.
    var commandRunner: CommandRunner? {
        didSet { refreshResults() }
    }

    /// The Maker's state machine — injected at wiring time; `nil` in tests
    /// that don't exercise `make`. While `makerPrompt` is non-nil the maker
    /// owns the panel (the view swaps the results list for `MakerView`).
    var maker: MakerModel? {
        didSet { refreshResults() }
    }

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refreshResults()
        }
    }

    @Published private(set) var results: [ResultRow] = [] {
        didSet {
            // A replaced list is a new result set: restart at the top row —
            // Spotlight-style — rather than keeping an index that now names
            // an unrelated row.
            selection = 0
        }
    }

    @Published var selection = 0

    /// The currently selected row, or `nil` when there are no results.
    var selectedRow: ResultRow? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    // MARK: Maker routing

    /// Keywords that route the query into the Maker — `make ` and `mk `
    /// (PLAN §6). The bare keyword without a trailing space stays a normal
    /// search, same convention as filter-mode commands.
    static let makerKeywords = ["make", "mk"]

    /// The make-request text when `query` is `make <prompt>`/`mk <prompt>`,
    /// else nil. Checked before filter routing — the built-in wins if a
    /// command ever claims "make" as its keyword.
    var makerPrompt: String? {
        for keyword in Self.makerKeywords {
            let prefix = keyword + " "
            if query.hasPrefix(prefix) {
                return String(query.dropFirst(prefix.count))
            }
        }
        return nil
    }

    /// Whether the Maker view owns the panel right now — the prefix is
    /// typed AND a maker is wired (unwired, "make x" stays a normal search).
    var makerIsActive: Bool {
        makerPrompt != nil && maker != nil
    }

    // MARK: Searching

    /// Re-runs the current query. Called on query changes and by
    /// `AppSource.onReload`/`CommandSource.onReload` — a background scan
    /// landing after the panel opened must fill the visible list without
    /// waiting for the next keystroke.
    func refreshResults() {
        // The maker owns the panel: `MakerView` replaces the list, and a
        // command source rescan must not refill rows nobody can see.
        if makerIsActive {
            filterTask?.cancel()
            filterTask = nil
            activeFilterKeyword = nil
            // Same stale-drop as the mode-exit path: an in-flight filter
            // run must not stamp rows over the maker-owned panel.
            filterGeneration += 1
            if !results.isEmpty { results = [] }
            return
        }
        if let resolved = activeFilter() {
            scheduleFilter(resolved.command, keyword: resolved.keyword,
                           text: resolved.text)
            return
        }
        filterTask?.cancel()
        filterTask = nil
        activeFilterKeyword = nil
        // A filter task awaiting runner.query ignores cancellation
        // cooperatively — bump the generation so its late completion is
        // discarded rather than stamped over the fresh search rows.
        filterGeneration += 1
        let newResults = (searchModel?.results(for: query) ?? []).map(ResultRow.init)
        // A background rescan landing identical rows must not yank the
        // selection back to the top (results' didSet resets it) or fire a
        // redundant objectWillChange.
        guard newResults != results else { return }
        results = newResults
    }

    // MARK: Filter mode

    /// Debounce for filter-mode re-runs — PLAN §4.1's ~80 ms.
    private static let filterDebounceNanoseconds: UInt64 = 80_000_000

    private var filterTask: Task<Void, Never>?
    /// Stale-drop: a result arriving for an older keystroke is discarded.
    private var filterGeneration = 0
    /// Filter runs that reached the main-actor completion point — lets
    /// tests wait out the debounce deterministically instead of sleeping.
    /// Counts completions whether or not the rows were kept.
    private(set) var filterRunCompletions = 0
    /// Filter runs actually submitted to the runner — tests await this to
    /// know a debounced run is genuinely in flight before mutating the
    /// query, where a fixed sleep could lose to a slow scheduler.
    private(set) var filterRunsStarted = 0
    /// The trigger word owning the list right now, so entering/leaving a
    /// filter session can clear rows that don't belong to it. Keyed by the
    /// keyword, not the command name — two commands can share a display
    /// name, and switching between them must clear the old rows.
    private var activeFilterKeyword: String?
    /// The command a picked `.enterFilter` row pinned this session to.
    /// Keyword routing is ambiguous when two commands claim the same
    /// trigger; the pin keeps the session on the command the user chose.
    /// Cleared as soon as the query's first token no longer matches.
    private var pinnedFilter: (keyword: String, commandName: String)?

    /// The resolved session when `query` is `<keyword> <rest>` for a
    /// filter-mode command. The bare keyword (no space) stays a normal
    /// search — that's how the user picks the command to enter its mode.
    /// A pinned row-pick resolves by name, bypassing keyword collisions.
    private func activeFilter() -> (command: Command, keyword: String, text: String)? {
        guard let spaceIndex = query.firstIndex(of: " ") else {
            pinnedFilter = nil
            return nil
        }
        let keyword = String(query[..<spaceIndex])
        let text = String(query[spaceIndex...].dropFirst())
        if let pinned = pinnedFilter {
            if pinned.keyword == keyword,
               let command = commandLookup?(pinned.commandName),
               command.manifest.mode == .filter {
                return (command, keyword, text)
            }
            pinnedFilter = nil
        }
        guard let command = filterLookup?(keyword) else { return nil }
        return (command, keyword, text)
    }

    /// Debounced per-keystroke run (PLAN §4.1). Results replace the list on
    /// arrival; a generation counter drops responses for stale queries.
    private func scheduleFilter(_ command: Command, keyword: String, text: String) {
        // Entering a different trigger's filter session clears the previous
        // list — otherwise the old session's rows linger during the debounce.
        if activeFilterKeyword != keyword {
            activeFilterKeyword = keyword
            results = []
        }
        filterGeneration += 1
        let generation = filterGeneration
        filterTask?.cancel()
        filterTask = Task {
            try? await Task.sleep(nanoseconds: Self.filterDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run { filterRunsStarted += 1 }
            let rows = await Self.filterRows(command: command, text: text,
                                             runner: commandRunner)
            await MainActor.run {
                // Count every completion — dropped ones too — but only
                // after this run's effects land, so a poller that sees the
                // tick also sees the final rows/selection state.
                defer { filterRunCompletions += 1 }
                // Identical rows must not re-assign: results' didSet resets
                // the selection, so a no-op refresh would yank it to the top.
                guard generation == filterGeneration, rows != results else { return }
                results = rows
            }
        }
    }

    /// Runs one filter query and maps the result — including failures — to
    /// rows. Off the actor: `CommandRunner.query` is already async.
    private static func filterRows(command: Command, text: String,
                                   runner: CommandRunner?) async -> [ResultRow] {
        let manifest = command.manifest
        guard let runner else {
            return errorRows(command: manifest.name,
                             message: "command runtime unavailable")
        }
        do {
            let items = try await runner.query(command: command, text: text)
            return commandRows(command: command, items: items)
        } catch {
            return errorRows(command: manifest.name,
                             message: error.localizedDescription)
        }
    }

    /// What picking a filter row does. `arg` is the payload: an http(s) URL
    /// opens, anything else copies. No arg copies the title — a row with
    /// nothing to do still does something harmless.
    private static func filterAction(for item: JSResult.Item) -> Item.Action {
        guard let arg = item.arg else { return .copyText(item.title) }
        if let url = URL(string: arg),
           url.scheme == "http" || url.scheme == "https" {
            return .openURL(url)
        }
        return .copyText(arg)
    }

    /// Replaces the list with a finished action-mode command's `{items}`
    /// output (PLAN §4.1) so the user can pick a row. Any in-flight filter
    /// task is cancelled — these rows are the list now.
    func showCommandResults(_ rows: [ResultRow]) {
        filterTask?.cancel()
        filterTask = nil
        activeFilterKeyword = nil
        // Replacing the list resets the selection to the top row via the
        // results didSet — a fresh command output is a new result set.
        results = rows
    }

    /// Maps a `JSResult.Item` to a row under `command`'s filter-row
    /// namespace. Shared by filter-mode runs and action-mode `{items}`.
    static func commandRows(command: Command, items: [JSResult.Item]) -> [ResultRow] {
        let manifest = command.manifest
        return items.enumerated().map { index, item in
            ResultRow(
                id: Item.filterRowIDPrefix + manifest.name + ":\(index)",
                title: item.title,
                subtitle: item.subtitle ?? "",
                icon: .symbol(item.icon ?? manifest.icon ?? "terminal"),
                action: filterAction(for: item))
        }
    }

    /// One-row error list for a failed command run — the message is both
    /// the subtitle and the row's payload so picking it copies the error.
    static func errorRows(command: String, message: String) -> [ResultRow] {
        [ResultRow(id: Item.filterRowIDPrefix + command + ":error",
                   title: "Command failed",
                   subtitle: message,
                   icon: .symbol("exclamationmark.triangle"),
                   action: .copyText(message))]
    }

    // MARK: State changes

    /// Prepares a fresh summon: selection back to the first row, query cleared
    /// unless the caller keeps it (the "keep query on re-show" setting).
    func reset(clearQuery: Bool) {
        if clearQuery { query = "" }
        selection = 0
    }

    /// Moves the selection by `delta` rows, wrapping at both ends.
    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let count = results.count
        // Double modulo: plain `%` would go out of range for negative deltas.
        selection = ((selection + delta) % count + count) % count
    }

    /// Selects `row` directly — mouse taps land here rather than moving the
    /// index one step at a time.
    func select(_ row: ResultRow) {
        guard let index = results.firstIndex(of: row) else { return }
        selection = index
    }

    /// Hands the selected row (or `nil`, when there are no results) to
    /// `onSubmit` — except `.enterFilter`, which stays inside the panel:
    /// the query expands to `"<keyword> "`, entering the command's filter
    /// mode instead of dismissing.
    func submit() {
        // While the maker owns the panel ⏎ means "advance the maker flow"
        // (generate when idle, save when clean) — `MakerModel` decides.
        if makerIsActive, let maker, let prompt = makerPrompt {
            Task { await maker.primarySubmit(prompt: prompt) }
            return
        }
        if let row = selectedRow,
           case .enterFilter(let keyword, let commandName) = row.action {
            // Pin the session to the picked command — its trigger word may
            // collide with another command's, and the row the user chose
            // must be the one that owns the expanded query.
            pinnedFilter = (keyword, commandName)
            query = keyword + " "
            return
        }
        onSubmit?(selectedRow)
    }
}
