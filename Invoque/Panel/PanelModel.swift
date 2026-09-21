import AppKit
import Foundation
import PictKit

/// One selectable row in the launcher's results list: the display fields of
/// an `Item` plus the action picking it performs. The view never sees `Item`
/// itself — rows are the panel's presentation shape.
struct ResultRow: Identifiable, Equatable {

    let id: String
    let title: String
    let subtitle: String
    let icon: Item.Icon
    let action: Item.Action
    /// The row's search surface — kept on the row so an extended query can
    /// re-check "still matches" without going back to the source `Item`.
    let matchText: String

    init(item: Item) {
        self.init(id: item.id, title: item.title, subtitle: item.subtitle,
                  icon: item.icon, action: item.action,
                  matchText: item.matchText)
    }

    /// Direct construction for rows that aren't `Item`s — filter-mode
    /// results and error rows.
    init(id: String, title: String, subtitle: String,
         icon: Item.Icon, action: Item.Action, matchText: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.action = action
        self.matchText = matchText ?? title
    }

    /// Equality covers display fields only — `matchText` is derived search
    /// metadata, and counting it would turn a visually identical rescan
    /// into a "change" that resets the selection via `results`' didSet.
    static func == (lhs: ResultRow, rhs: ResultRow) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle && lhs.icon == rhs.icon
            && lhs.action == rhs.action
    }
}

/// View model for the launcher panel: query, results, and the selection
/// within them. Logic stays unit-testable — every side effect arrives
/// through an injectable closure or a wired hook.
///
/// The search is synchronous: sources serve cached data (`AppSource` holds
/// an in-memory scan; calculator/system/web compute in microseconds), so a
/// `results(for:)` per keystroke stays on the main thread by design.
/// `Sendable` is asserted: every member is main-queue confined — the model
/// is the panel's UI state and is only ever driven from the main thread.
/// The annotation exists so a reference can ride a `@Sendable` hop *back*
/// to main, not to license off-main use.
final class PanelModel: ObservableObject, @unchecked Sendable {

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

    /// Runs a Spotlight-free filename scan (`FileSearch.stream` in
    /// production, a stub in tests). `emit` delivers the accumulated
    /// ranked snapshot — never a delta — as the walk finds matches, so
    /// results stream into the list. While `nil`, `find`/`f`/`search`
    /// queries stay normal searches — the same "unwired stays normal"
    /// convention as `filterLookup` and `maker`.
    var fileSearcher: FileSearchSession.Searcher? {
        didSet { refreshResults() }
    }

    /// Fires when the user detaches an in-flight file scan — the
    /// controller hands `session` to a standalone results window and
    /// hides the panel. Unwired (tests), ⏎ during a pending scan falls
    /// through to the normal submit path.
    var onDetachFileSearch: ((FileSearchSession) -> Void)?

    /// Fans a rules change out to surfaces that shape their own lists —
    /// the detached file-search window — since `Preferences.
    /// entryRulesChanged` is a single-subscriber hook wired here.
    var onEntryRulesChanged: (() -> Void)?

    /// The user's pin/block rules — Preferences-backed in production via
    /// the AppDelegate's wiring; the default instance manages nothing.
    /// Reads are live closures, so a Settings edit lands on the next
    /// refresh; writes from Settings fire `entryRulesDidChange` through
    /// `Preferences.entryRulesChanged`.
    var entryRules = EntryRules() {
        didSet { refreshResults() }
    }

    /// Shared-store icon lookup: the resolved artwork for a target, or nil
    /// for "use the system icon" — `PictKit`'s miss contract, which the
    /// view reads as "draw the workspace icon". Wired to `InvoqueIcons` by
    /// the AppDelegate; `nil` in tests, where rows draw workspace icons.
    var iconResolver: ((IconTarget) -> NSImage?)?

    /// Shared-store artwork landed or an external write invalidated it —
    /// drop the accent cache (it sampled the old icons) and republish so
    /// rows redraw with the new artwork. `InvoqueIcons.onIconsInvalidated`
    /// is wired here by the AppDelegate; both of its callbacks arrive on
    /// the main queue.
    func noteIconsChanged() {
        AdaptiveAccent.invalidate()
        objectWillChange.send()
    }

    /// The Maker's state machine — injected at wiring time; `nil` in tests
    /// that don't exercise `make`. While `makerPrompt` is non-nil the maker
    /// owns the panel (the view swaps the results list for `MakerView`).
    @Published var maker: MakerModel? {
        didSet { refreshResults() }
    }

    /// A command run paused on first-run consent (PLAN §4.3). While set,
    /// the panel shows the confirmation card instead of the results list
    /// and ⌘⏎ means Allow.
    @Published var permissionRequest: CommandPermissionRequest?

    /// Fires after the user allows a `permissionRequest` — the controller
    /// records the grant and re-dispatches the run. Granting lives on the
    /// controller side (where the ungranted check runs), so an unwired or
    /// divergent store can't make Allow loop on the card forever.
    var onPermissionConfirmed: ((CommandPermissionRequest) -> Void)?

    /// Releases the paused run to the controller — it grants and resumes.
    func confirmPermissionRequest() {
        guard let request = permissionRequest else { return }
        permissionRequest = nil
        onPermissionConfirmed?(request)
    }

    /// Declines the request: no grant, no run — back to the results list.
    func dismissPermissionRequest() {
        permissionRequest = nil
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

    // MARK: File-search routing

    /// Keywords that route the query into file-search mode — `find `,
    /// `f ` (Alfred's `find` muscle memory), and `search `. The bare
    /// keyword without a trailing space stays a normal search, and the
    /// built-in wins over a command claiming the same keyword — the
    /// `makerKeywords` policy. Note `search ` deliberately reroutes what
    /// used to be a normal (web-fallback) query into file mode — call it
    /// out in release notes.
    static let fileSearchKeywords = ["find", "f", "search"]

    /// The resolved `find`/`f`/`search` session when `query` is
    /// `<keyword> <rest>`
    /// and a searcher is wired, else nil. `text` is whitespace-trimmed —
    /// "f  x" scans "x", and a spaces-only rest resolves blank. Blank owns
    /// an empty list until there's something worth scanning for.
    private func activeFileSearch() -> (keyword: String, text: String)? {
        guard fileSearcher != nil,
              let spaceIndex = query.firstIndex(of: " ") else { return nil }
        let keyword = String(query[..<spaceIndex])
        guard Self.fileSearchKeywords.contains(keyword) else { return nil }
        let text = String(query[spaceIndex...].dropFirst())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (keyword, text)
    }

    /// Whether a file scan owns the list right now — the prefix is typed
    /// AND a searcher is wired. The footer reads this to show the
    /// open/reveal hints.
    var fileSearchIsActive: Bool {
        activeFileSearch() != nil
    }

    /// True in file mode when the text after the keyword is blank — the
    /// view shows an input hint rather than claiming zero matches.
    var fileSearchTextIsBlank: Bool {
        activeFileSearch()?.text.isEmpty ?? false
    }

    /// True between scheduling a scan and its last batch landing — the
    /// view says "Searching files…" rather than a premature "No matching
    /// files". `fileSession` is nilled on completion, cancel, mode exit,
    /// or detach.
    var fileScanIsPending: Bool {
        fileSession != nil && fileSearchIsActive
    }

    // MARK: Searching

    /// The normal-search text that produced `results` — the stability
    /// anchor. Extending it keeps still-matching rows in place (see
    /// `stabilizedRankedRows`); `nil` while another mode owns the list so
    /// stability can't leak a foreign session's rows into a fresh search.
    private var rankedText: String?

    /// Re-runs the current query. Called on query changes and by
    /// `AppSource.onReload`/`CommandSource.onReload` — a background scan
    /// landing after the panel opened must fill the visible list without
    /// waiting for the next keystroke.
    func refreshResults() {
        // The maker owns the panel: `MakerView` replaces the list, and a
        // command source rescan must not refill rows nobody can see.
        if makerIsActive {
            rankedText = nil
            cancelFileSearch()
            cancelFilterRun()
            if !results.isEmpty { results = [] }
            return
        }
        // Built-in keywords win over filter commands claiming them — the
        // `makerKeywords` policy.
        if let resolved = activeFileSearch() {
            rankedText = nil
            cancelFilterRun()
            scheduleFileSearch(keyword: resolved.keyword, text: resolved.text)
            return
        }
        if let resolved = activeFilter() {
            rankedText = nil
            cancelFileSearch()
            scheduleFilter(resolved.command, keyword: resolved.keyword,
                           text: resolved.text)
            return
        }
        cancelFileSearch()
        cancelFilterRun()
        let fresh = searchModel?.results(for: query) ?? []
        let newResults = stabilizedRankedRows(fresh)
        rankedText = query
        // A background rescan landing identical rows must not yank the
        // selection back to the top (results' didSet resets it) or fire a
        // redundant objectWillChange.
        guard newResults != results else { return }
        results = newResults
    }

    /// Maps fresh items to rows, preserving the displayed order of rows
    /// that still match when the query only grew: extending "saf" to "safa"
    /// must not bounce a still-matching row out of its slot — the user is
    /// already reaching for it. Re-sorting can't promise that (a prefix
    /// hit can degrade to infix while still matching, e.g. "saf"→"safa"
    /// against "SafxSafay"), so survivors keep their relative order and
    /// newcomers fill the remaining slots by rank — *except* where a row's
    /// fresh rank is strictly better than the rows ahead of it, which
    /// `promote` allows to rise. A survivor absent from `fresh` but still
    /// matching (pushed past the result cap) keeps its row; its display
    /// fields refresh from the fresh copy when one exists.
    /// Pinned rows (calculator up top, web fallback at the bottom) keep
    /// their slots — stability only covers the ranked middle.
    private func stabilizedRankedRows(_ fresh: [Item]) -> [ResultRow] {
        let freshRows = fresh.map(ResultRow.init)
        guard let anchor = rankedText, !anchor.isEmpty,
              query != anchor, query.hasPrefix(anchor) else {
            return freshRows
        }
        // The survivor re-match must use the model's own normalization —
        // a looser form here would keep rows the model already dropped.
        let trimmed = SearchModel.normalizedQuery(query)
        let freshByID = Dictionary(freshRows.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        var head: [RankedRow] = []
        var headIDs = Set<String>()
        for row in results where !Item.isPinnedID(row.id) {
            // Prefer the fresh copy's match surface when one exists — a
            // rescan that renames what the item matches must not keep
            // displaying a row that no longer qualifies.
            let candidate = freshByID[row.id]?.matchText ?? row.matchText
            guard let match = FuzzyMatcher.match(trimmed,
                                                 candidate: candidate),
                  headIDs.insert(row.id).inserted else { continue }
            head.append(rankedRow(freshByID[row.id] ?? row,
                                  match: match, text: trimmed))
        }
        // The pins keep their slots around the ranked middle — a head
        // survivor must not push a fresh calculator answer off the top,
        // and the cap applies to the middle only or a full page of
        // survivors would slice the web fallback off the bottom. Same
        // slot math as SearchModel's own `rankedSlots`.
        let tail = freshRows
            .filter { !Item.isPinnedID($0.id) && !headIDs.contains($0.id) }
            .map { rankedRow($0, match: FuzzyMatcher.match(
                trimmed, candidate: $0.matchText), text: trimmed) }
        let headPins = freshRows.filter { Item.isHeadPinnedID($0.id) }
        let web = freshRows.filter { $0.id.hasPrefix(Item.webIDPrefix) }
        let middleSlots = max(0, SearchModel.maxResults
            - headPins.count - web.count)
        return Array((headPins
            + Array(promote(head + tail).prefix(middleSlots)) + web)
            .prefix(SearchModel.maxResults))
    }

    /// A row plus the rank keys the stability merge sorts by. The keys
    /// describe the row's rank under the *new* query — promotion exists
    /// precisely because they can improve while a row sits displayed.
    private struct RankedRow {
        let row: ResultRow
        /// Entry pins hold the lead through a merge — a stronger-matching
        /// row must not bubble past the pin contract.
        let pinned: Bool
        let tier: FuzzyMatcher.Match.Tier
        /// Whether the query occurs contiguously in the displayed title —
        /// `SearchModel.outranks`' second key: a hit the user can see
        /// beats one hiding in the match-only surface.
        let inTitle: Bool
    }

    /// Builds a `RankedRow`: the match/tier under the current text plus
    /// the pin and title-hit keys. `match` is nil only defensively —
    /// every caller already filtered on a hit.
    private func rankedRow(_ row: ResultRow, match: FuzzyMatcher.Match?,
                           text: String) -> RankedRow {
        RankedRow(row: row, pinned: entryRules.isPinned(row.id),
                  tier: match?.tier ?? .fuzzy,
                  inTitle: match != nil
                      && FuzzyMatcher.contains(text, in: row.title))
    }

    /// Stable merge of survivors-then-newcomers: input order wins among
    /// equal keys — that's the stability half, the still-matching row
    /// keeps the slot the user sees it in — but a strictly better key
    /// (pinned over unpinned, better tier, title hit over hidden)
    /// promotes past worse peers. That's the half absolute-position
    /// preservation got wrong: "para" kept "Parallels Desktop" buried
    /// below fuzzy survivors because nothing could ever move up.
    private func promote(_ rows: [RankedRow]) -> [ResultRow] {
        rows.enumerated().sorted { lhs, rhs in
            let l = lhs.element, r = rhs.element
            if l.pinned != r.pinned { return l.pinned }
            if l.tier != r.tier { return l.tier < r.tier }
            if l.inTitle != r.inTitle { return l.inTitle }
            return lhs.offset < rhs.offset
        }.map(\.element.row)
    }

    /// Stops any scheduled or in-flight filter run and bumps the
    /// generation — a task awaiting `runner.query` ignores cancellation
    /// cooperatively, so the late completion must also be discarded rather
    /// than stamped over whatever replaced it.
    private func cancelFilterRun() {
        filterTask?.cancel()
        filterTask = nil
        activeFilterKeyword = nil
        filterGeneration += 1
    }

    /// The `cancelFilterRun` twin for `find`/`f` sessions.
    private func cancelFileSearch() {
        cancelFileSession()
        activeFileKeyword = nil
        activeFileText = nil
        fileResultText = nil
        rawFileRows = []
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

    // MARK: File-search mode

    /// Debounce for `find`/`f` re-scans — longer than the filter debounce:
    /// a directory walk costs more per run than a JS query. `var` so timing
    /// tests shrink it instead of sleeping past the production value.
    static var fileSearchDebounceNanoseconds: UInt64 = 150_000_000

    /// The live `find`/`f` session — owns the debounced walk and the
    /// accumulated items. @Published so a completion that clears the
    /// handle without touching `results` (identical rows) still
    /// republishes — `fileScanIsPending` must flip to false in the view
    /// or "Searching files…" sticks. Session identity replaces the old
    /// generation counter for stale-dropping: a finished session's
    /// callbacks check `session === fileSession`.
    @Published private var fileSession: FileSearchSession?
    /// File scans that reached their finish callback — the test hook
    /// mirroring `filterRunCompletions`. Counts finishes whether the
    /// session was current, stale, or cancelled mid-flight — a poller
    /// waiting on the tick sees settled state either way.
    private(set) var fileRunCompletions = 0
    /// File scans actually started (past the debounce) — mirrors
    /// `filterRunsStarted`.
    private(set) var fileRunsStarted = 0
    /// The keyword owning the list right now — switching modes clears rows
    /// that don't belong to the new session (see `activeFilterKeyword`).
    private var activeFileKeyword: String?
    /// The text the current file session last scheduled — a store-rescan
    /// `refreshResults` re-running the identical query skips a redundant
    /// disk walk.
    private var activeFileText: String?
    /// The file-search text that produced the current rows — the stability
    /// anchor for scan completions, mirroring `rankedText`. `nil` whenever
    /// `results` isn't a file-scan list.
    private var fileResultText: String?

    /// Debounced per-keystroke scan — the session streams batches into
    /// `results` as the walk finds them; a stale session's callbacks
    /// drop on the identity check in `fileSessionDidUpdate`.
    private func scheduleFileSearch(keyword: String, text: String) {
        // Identical session — this is a rescan-driven refresh, not a new
        // keystroke; restarting the walk would redo seconds of disk work
        // for the rows already on screen.
        if activeFileKeyword == keyword, activeFileText == text { return }
        // Entering file mode (or switching keywords) clears the previous
        // list — otherwise the old session's rows linger during the debounce.
        if activeFileKeyword != keyword {
            activeFileKeyword = keyword
            fileResultText = nil
            results = []
        }
        activeFileText = text
        cancelFileSession()
        // "find " with nothing after it owns an empty list — a blank query
        // would match everything and the cap would fill with junk. Clearing
        // on the guard-else covers backspacing to blank mid-session too.
        // `text` arrives pre-trimmed from `activeFileSearch`.
        guard !text.isEmpty, let searcher = fileSearcher else {
            fileResultText = nil
            if !results.isEmpty { results = [] }
            return
        }
        let session = FileSearchSession(
            query: query, text: text,
            debounceNanoseconds: Self.fileSearchDebounceNanoseconds,
            searcher: searcher)
        session.onStart = { [weak self] in self?.fileRunsStarted += 1 }
        session.onUpdate = { [weak self] in self?.fileSessionDidUpdate(session) }
        session.onFinish = { [weak self] in self?.fileSessionDidFinish(session) }
        fileSession = session
        session.start()
    }

    /// Drops the current session — nils the handle *before* cancelling so
    /// the synchronous `onFinish` inside `cancel()` reads as stale, not
    /// live (see `cancelFileSearch`).
    private func cancelFileSession() {
        let stale = fileSession
        fileSession = nil
        stale?.cancel()
    }

    /// A session emission landing: snapshot into `rawFileRows`, shape, and
    /// merge. Runs per batch while the walk streams — never at finish:
    /// every emission is already applied by its `absorb` → `onUpdate`
    /// hop, which posts before the finish hop on the FIFO main queue, so
    /// a finish-time re-apply would only double-merge (and, with
    /// `fileResultText` already advanced, undo an extension merge).
    private func fileSessionDidUpdate(_ session: FileSearchSession) {
        guard session === fileSession else { return }
        // Kept unshaped so a pin/block toggle can re-derive the list
        // without re-walking the disk. Scan-time rules are already
        // applied — blocked ids never arrive, pinned ones survive the
        // cap — so `shapeFileRows`' block drop only sees ids blocked
        // since the scan.
        let rows = session.items.map(ResultRow.init)
        rawFileRows = rows
        let merged = stabilizedFileRows(shapeFileRows(rows), text: session.text)
        fileResultText = session.text
        // Identical rows must not re-assign: results' didSet resets
        // the selection, so a no-op refresh would yank it to the top.
        guard merged != results else { return }
        // Streaming batches replace the list mid-scan — track the
        // selection by row id so a merge inserting above the picked row
        // doesn't snap it back to the top.
        let selectedID = selectedRow?.id
        results = merged
        if let selectedID,
           let index = merged.firstIndex(where: { $0.id == selectedID }) {
            selection = index
        }
    }

    /// The session's walk ended — count it (stale ones too), then drop
    /// the handle, which flips `fileScanIsPending` for the footer. The
    /// final snapshot is already applied — see `fileSessionDidUpdate`.
    /// The callbacks capture `session` strongly, so clearing them here
    /// breaks the session ↔ closure cycle — this one spot covers finish,
    /// cancel (which funnels through `finish` → `onFinish`), and stale
    /// sessions alike.
    private func fileSessionDidFinish(_ session: FileSearchSession) {
        defer { fileRunCompletions += 1 }
        session.onStart = nil
        session.onUpdate = nil
        session.onFinish = nil
        guard session === fileSession else { return }
        fileSession = nil
    }

    /// Hands the in-flight scan to a detached results window: the session
    /// keeps running — its subscriber is now the window's model — while
    /// the panel releases its reference without cancelling. The mode's
    /// bookkeeping clears so a later refresh can't mistake the detached
    /// scan for the panel's own.
    private func releaseFileSession() -> FileSearchSession? {
        guard let session = fileSession else { return nil }
        fileSession = nil
        session.onUpdate = nil
        session.onFinish = nil
        session.onStart = nil
        activeFileKeyword = nil
        activeFileText = nil
        fileResultText = nil
        rawFileRows = []
        if !results.isEmpty { results = [] }
        return session
    }

    /// The `stabilizedRankedRows` twin for file scans: when the scan text
    /// only grew, rows that still match keep their displayed positions and
    /// the fresh list fills the remaining slots by rank — with the same
    /// bounded promotion, so a file whose match tightened past its
    /// neighbours (fuzzy → infix → prefix) isn't stuck below the fold.
    /// Runs after `shapeFileRows`, so the merge sees the pin-ordered list —
    /// and only ever sees a text extension, since `entryRulesDidChange`
    /// applies rules changes wholesale instead of routing through here.
    private func stabilizedFileRows(_ freshRows: [ResultRow],
                                    text: String) -> [ResultRow] {
        guard let anchor = fileResultText, !anchor.isEmpty,
              text != anchor, text.hasPrefix(anchor) else {
            return freshRows
        }
        let freshByID = Dictionary(freshRows.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        var head: [RankedRow] = []
        var headIDs = Set<String>()
        for row in results {
            // Same rule as the ranked twin: the keep-check and the merge
            // key both read the fresh copy's surface when one exists —
            // a rescan that renames what the item matches must not keep
            // (or worse, promote) a row that no longer qualifies.
            let merged = freshByID[row.id] ?? row
            guard let match = FuzzyMatcher.match(text,
                                                 candidate: merged.matchText),
                  headIDs.insert(row.id).inserted else { continue }
            head.append(rankedRow(merged, match: match, text: text))
        }
        let tail = freshRows
            .filter { !headIDs.contains($0.id) }
            .map { rankedRow($0, match: FuzzyMatcher.match(
                text, candidate: $0.matchText), text: text) }
        return Array(promote(head + tail).prefix(SearchModel.maxResults))
    }

    /// The last scan's rows before pin/block shaping — cached so a rules
    /// change mid-session re-shapes the list without re-walking the disk.
    /// Cleared with the session in `cancelFileSearch`.
    private var rawFileRows: [ResultRow] = []

    /// Applies the entry rules to raw scan rows: blocked entries drop out,
    /// pinned entries lead — the file-mode twin of `SearchModel`'s pin
    /// band. `stabilizedFileRows` still owns positions on query extension.
    private func shapeFileRows(_ rows: [ResultRow]) -> [ResultRow] {
        let live = rows.filter { !entryRules.isBlocked($0.id) }
        return live.filter { entryRules.isPinned($0.id) }
            + live.filter { !entryRules.isPinned($0.id) }
    }

    // MARK: Entry rules (pin / block)

    /// Whether `row` is a durable entry the user can pin or block — the
    /// affordances never appear on functional pins or ephemeral rows.
    func canManage(_ row: ResultRow) -> Bool {
        Item.isManageableID(row.id)
    }

    func isPinned(_ row: ResultRow) -> Bool {
        entryRules.isPinned(row.id)
    }

    /// Toggles the pin on `row` (default: the selection). Returns HUD text
    /// describing the change, or nil when nothing happened — the row isn't
    /// a manageable entry, or a card (consent prompt, maker) owns the
    /// panel while the list sits underneath. The refresh arrives through
    /// the `entryRulesChanged` notification the write fires — toggles
    /// don't re-list directly, so there's exactly one refresh per write.
    @discardableResult
    func togglePin(on row: ResultRow? = nil) -> String? {
        guard permissionRequest == nil, !makerIsActive,
              let row = row ?? selectedRow, canManage(row) else { return nil }
        let pinned = entryRules.togglePin(row.id, row.title)
        return pinned ? "Pinned \(row.title)" : "Unpinned \(row.title)"
    }

    /// The `togglePin` twin for blocking — the row vanishes on the spot.
    @discardableResult
    func toggleBlock(on row: ResultRow? = nil) -> String? {
        guard permissionRequest == nil, !makerIsActive,
              let row = row ?? selectedRow, canManage(row) else { return nil }
        let blocked = entryRules.toggleBlock(row.id, row.title)
        return blocked ? "Blocked \(row.title)" : "Unblocked \(row.title)"
    }

    /// The sets changed — from a toggle here or from the Settings lists via
    /// `Preferences.entryRulesChanged`. File mode re-shapes the cached scan
    /// (`scheduleFileSearch` rightly refuses a same-session re-walk); a
    /// normal search just re-runs the open query.
    func entryRulesDidChange() {
        // Before the early-return below: the detached window's list is
        // not the panel's — it needs the same poke regardless of mode.
        onEntryRulesChanged?()
        if fileSearchIsActive {
            // Wholesale replace, not `stabilizedFileRows`: its survivor
            // merge exists for text extensions and a rules change is not
            // one — a pin must promote and a block must vanish on the spot.
            // `FileSearch` already caps its output at `maxResults`, but
            // enforce the list-height invariant here so a future producer
            // change can't push an over-cap list into the panel.
            let shaped = Array(shapeFileRows(rawFileRows)
                .prefix(SearchModel.maxResults))
            if shaped != results { results = shaped }
            return
        }
        refreshResults()
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
        rankedText = nil
        cancelFileSearch()
        cancelFilterRun()
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
        // A pending consent prompt belongs to the last summon — it must
        // not greet the next one.
        permissionRequest = nil
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
    ///
    /// `commandModifier` distinguishes plain ⏎ from ⌘⏎ — ⌘⏎ grants a
    /// pending consent request (so a habitual double-⏎ can't silently
    /// record a permanent `shell` grant) and reveals a file/app row in
    /// Finder instead of opening it.
    ///
    /// `detachesPendingScan` is the ⏎-mid-scan handoff. A tap on a row
    /// passes `false`: the tap is an explicit pick of *that* row, so it
    /// performs the row's action rather than floating the scan into a
    /// window.
    func submit(commandModifier: Bool = false,
                detachesPendingScan: Bool = true) {
        // A pending consent prompt swallows ⏎ — neutral, not "run whatever
        // row is selected underneath the card"; ⌘⏎ means Allow.
        if permissionRequest != nil {
            if commandModifier { confirmPermissionRequest() }
            return
        }
        // While the maker owns the panel ⏎ means "advance the maker flow"
        // (generate when idle, save when clean) — `MakerModel` decides.
        if makerIsActive, let maker, let prompt = makerPrompt {
            Task { await maker.primarySubmit(prompt: prompt) }
            return
        }
        // While a file scan is streaming, its rows are provisional — ⏎
        // doesn't pick one (and hiding the panel would strand the walk).
        // It detaches the session into its own window, where the walk
        // keeps streaming and the settled rows stay actionable. Unwired,
        // this falls through to the normal submit path. Taps skip this —
        // a tap is a pick, not a detach (see the doc comment).
        if detachesPendingScan, fileScanIsPending,
           let detach = onDetachFileSearch,
           let session = releaseFileSession() {
            detach(session)
            return
        }
        if let row = selectedRow,
           case .enterFilter(let keyword, let commandName) = row.action {
            // The pick is consumed here — onSubmit never runs — so
            // frecency training happens in the model or a heavily used
            // filter command never rises in the ranked list.
            searchModel?.recordSelection(itemID: row.id)
            // Pin the session to the picked command — its trigger word may
            // collide with another command's, and the row the user chose
            // must be the one that owns the expanded query.
            pinnedFilter = (keyword, commandName)
            query = keyword + " "
            return
        }
        // ⌘⏎ on a file or app reveals it in Finder instead of opening —
        // Alfred's `find` gesture. The consent check above already claimed
        // ⌘⏎, so a pending prompt can't be bypassed by a file row.
        if commandModifier, let row = selectedRow {
            switch row.action {
            case .openFile(let url), .openApp(let url):
                onSubmit?(ResultRow(id: row.id, title: row.title,
                                    subtitle: row.subtitle, icon: row.icon,
                                    action: .revealInFinder(url)))
                return
            case .revealInFinder(let url):
                // The inverse — a pasted file *path* reveals on plain ⏎,
                // so ⌘⏎ is the open gesture there (only `PathSource`
                // emits reveal actions). Executables stay on reveal on
                // either gesture — opening an .app or a +x file runs it.
                let opens = PathSource.isSafeToOpen(url)
                onSubmit?(ResultRow(id: row.id, title: row.title,
                                    subtitle: row.subtitle, icon: row.icon,
                                    action: opens ? .openFile(url) : .revealInFinder(url)))
                return
            default:
                break
            }
        }
        onSubmit?(selectedRow)
    }
}
