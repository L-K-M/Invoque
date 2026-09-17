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

    // MARK: Icon

    /// How the results list renders this item. No image data lives here; the
    /// view resolves the icon lazily so the search hot path stays cheap.
    enum Icon: Equatable {
        /// An SF Symbol name, e.g. `"lock.fill"`.
        case symbol(String)
        /// An image file on disk.
        case fileURL(URL)
        /// A bundle path whose app icon should be shown.
        case appIcon(String)
    }

    // MARK: Action

    /// What picking this item does. Data only; the panel performs it.
    enum Action: Equatable {
        case openApp(URL)
        case openURL(URL)
        case copyText(String)
        case runCommand(String, [String])
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
    }
}
