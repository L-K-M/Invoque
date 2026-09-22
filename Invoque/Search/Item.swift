import Foundation

/// A single launchable row in the results list: an app, a command, a system
/// action, a calculator result, or the web-search fallback.
///
/// `Identifiable` by a stable namespaced id, so frecency and selection
/// history survive rescans and reorderings. Data only: the panel owns how an
/// item looks and what happens when it is picked.
struct Item: Identifiable, Equatable {

    /// Id namespaces. Sources build ids from these prefixes so `SearchModel`
    /// can apply source priorities without knowing the sources. The prefixes
    /// are part of the persisted frecency keys, so never change them.
    static let appIDPrefix = "app:"
    static let commandIDPrefix = "cmd:"
    static let systemIDPrefix = "sys:"
    static let webIDPrefix = "web:"
    static let calculatorIDPrefix = "calc:"
    /// Rows produced by a filter-mode command's per-keystroke run. Their
    /// index-based ids are meaningless across queries, so frecency must
    /// never record them (see `SearchModel.recordSelection`).
    static let filterRowIDPrefix = "filter:"
    /// Rows produced by `FileSearch` (`find`/`f` mode). They bypass
    /// `SearchModel` like filter rows, so frecency never reads them —
    /// excluded from `recordSelection` eligibility for the same reason.
    static let fileIDPrefix = "file:"
    /// The one row `PathSource` emits when the query *is* an existing
    /// filesystem path. Pinned first — a typed address is a direct intent,
    /// not a candidate among fuzzy matches.
    static let pathIDPrefix = "path:"
    /// Generator rows (`uuid`, `now`, `flip`, `roll`) — instant answers,
    /// one stable id per generator so selection behaves while values are
    /// fresh per query.
    static let generatorIDPrefix = "gen:"
    /// The one row `URLSource` emits when the query *is* an http(s) URL.
    /// Pinned alongside `path:` for the same reason — and so the web
    /// fallback can't own ⏎ on a pasted address.
    static let urlIDPrefix = "url:"

    /// Whether an id belongs to a pinned row — one that bypasses ranking
    /// entirely. One place so `SearchModel` and `PanelModel` can't drift.
    static func isPinnedID(_ id: String) -> Bool {
        isHeadPinnedID(id) || id.hasPrefix(webIDPrefix)
    }

    /// The pins that lead the list — path, URL, and calculator. The web
    /// fallback pins *last* instead, so it isn't a head pin.
    static func isHeadPinnedID(_ id: String) -> Bool {
        id.hasPrefix(pathIDPrefix) || id.hasPrefix(urlIDPrefix)
            || id.hasPrefix(calculatorIDPrefix)
    }

    /// Whether an id names a user-manageable *entry* — one that can be
    /// pinned (rank above other matches) or blocked (never show). Apps,
    /// commands, system actions and files have durable ids; functional
    /// pins (`path:`/`calc:`/`web:`) and ephemeral `filter:` rows aren't
    /// entries, so the pin/block affordances never appear on them.
    static func isManageableID(_ id: String) -> Bool {
        [appIDPrefix, commandIDPrefix, systemIDPrefix, fileIDPrefix]
            .contains { id.hasPrefix($0) }
    }

    /// Stable namespaced id, e.g. `"app:com.apple.Safari"`,
    /// `"cmd:format-json"`, `"sys:lockScreen"`, `"web:safari"`, `"calc:2+2"`.
    let id: String
    let title: String
    let subtitle: String
    let icon: Icon
    let action: Action

    /// The string the matcher scores, usually the title plus extra keywords.
    /// Kept separate from `title` so sources can add invisible match words.
    let matchText: String

    /// The source category, derived from the id prefix. Used for the
    /// colored source badge in result rows — a quick visual cue for where
    /// a result came from.
    var sourceType: SourceType {
        if id.hasPrefix(Self.appIDPrefix) { return .app }
        if id.hasPrefix(Self.commandIDPrefix) { return .command }
        if id.hasPrefix(Self.systemIDPrefix) { return .system }
        if id.hasPrefix(Self.fileIDPrefix) { return .file }
        if id.hasPrefix(Self.pathIDPrefix) { return .path }
        if id.hasPrefix(Self.calculatorIDPrefix) { return .calculator }
        if id.hasPrefix(Self.webIDPrefix) { return .web }
        if id.hasPrefix(Self.filterRowIDPrefix) { return .filter }
        return .unknown
    }

    /// Source categories for the colored badge.
    enum SourceType: String {
        case app, command, system, file, path, calculator, web, filter, unknown
    }

    // MARK: Icon

    /// How the results list renders this item. No image data lives here; the
    /// view resolves the icon lazily so the search hot path stays cheap.
    enum Icon: Equatable {
        /// An SF Symbol name, e.g. `"lock.fill"`.
        case symbol(String)
        /// An image file on disk.
        case fileURL(URL)
        /// A bundle path whose app icon should be shown. `bundleID` feeds
        /// the shared-store lookup ladder (path first, identifier second —
        /// a Pict override follows the app when it moves).
        case appIcon(path: String, bundleID: String?)
    }

    // MARK: Action

    /// What picking this item does. Data only; the panel performs it.
    enum Action: Equatable {
        case openApp(URL)
        case openURL(URL)
        /// Open a file in its default app — the `find` mode's ⏎.
        case openFile(URL)
        /// Show the file/app in Finder — ⌘⏎ on an `openFile`/`openApp` row
        /// (`PanelModel.submit` performs the swap).
        case revealInFinder(URL)
        case copyText(String)
        case runCommand(String, [String])
        /// Enter a filter-mode command: the panel expands the query to
        /// `"<keyword> "` rather than dismissing. `PanelModel.submit`
        /// intercepts this case, so performers never see it. `commandName`
        /// pins the session to this exact command — two commands can claim
        /// the same trigger word, and the picked row must win.
        case enterFilter(keyword: String, commandName: String)
        case system(SystemAction)
    }

    // MARK: SystemAction

    /// Fixed macOS actions served by `SystemSource`. Raw values appear in
    /// item ids (`"sys:lockScreen"`) and persisted frecency, so never rename
    /// them.
    enum SystemAction: String, Equatable, CaseIterable {
        case lockScreen
        case sleep
        case restart
        case shutDown
        case emptyTrash

        /// Actions that can destroy data or interrupt the user's session.
        var requiresConfirmation: Bool {
            switch self {
            case .restart, .shutDown, .emptyTrash:
                return true
            case .lockScreen, .sleep:
                return false
            }
        }

        /// Canonical SF Symbol — the source row and the confirmation card
        /// both derive from this so their glyphs can never drift.
        var symbolName: String {
            switch self {
            case .restart: return "arrow.counterclockwise"
            case .shutDown: return "power"
            case .emptyTrash: return "trash.fill"
            case .lockScreen: return "lock.fill"
            case .sleep: return "moon.fill"
            }
        }
    }
}
