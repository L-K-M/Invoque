import AppKit
import PictKit

/// Invoque's side of the shared icon store.
///
/// `PictKit` owns the store, the resolution ladder and the cache — the same
/// pieces Jetty reaches through `JettyIcons` and Zap through `ZapIcons`.
/// What lives here is what is really *about Invoque*: the render options a
/// result row wants, the shared-store watcher, and the invalidation hook
/// that tells the panel its icons have stopped being the right ones.
final class InvoqueIcons {

    static let shared = InvoqueIcons()

    let store: IconStore
    /// Thread-safe by construction — `IconResolver` guards its cache with a
    /// lock and resolves on its own queue — so this type carries no actor
    /// isolation and `icon(for:)` is callable from wherever a row renders.
    let resolver: IconResolver

    /// Fires when the panel's icons have stopped being the right ones:
    /// shared-store artwork landed (`onIconsResolved`), or another app —
    /// Pict, Zap, Jetty, Top Drawer — rewrote the store. `PanelModel` drops
    /// the accent cache and republishes on it.
    var onIconsInvalidated: (() -> Void)?

    private var watcher: IconStoreWatcher?
    private var screenObserver: NSObjectProtocol?

    private init(store: IconStore = IconStore()) {
        // `backingScale()` reads `NSScreen.screens`, which is
        // main-thread-only, and this type carries no isolation to enforce
        // that — so assert the contract (first access is the AppDelegate's
        // wiring or a view body, both main) rather than trusting it.
        dispatchPrecondition(condition: .onQueue(.main))
        self.store = store
        // A result row sits in a compact list — `bleed: 0` and no baked
        // shadow, the same call Jetty makes for its tile grid. Artwork
        // spilling into the neighbouring row is the look Zap's switcher is
        // after and exactly the wrong one here.
        self.resolver = IconResolver(options: .plain(pointSize: Self.rowPointSize,
                                                     scale: Self.backingScale()),
                                     store: store)
        watch()
        watchScreens()
        // The other half of the store watcher. A first `icon(for:)` call is
        // usually a miss — the row falls back to the system icon while the
        // resolve warms in the background — so artwork landing later must
        // still trigger a redraw, or the row stays on the fallback until
        // relaunch.
        resolver.onIconsResolved = { [weak self] in self?.onIconsInvalidated?() }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    /// The size a result row draws its icon — `ResultRowView`'s 28pt
    /// column. Icons are cached at one size; the row never varies it.
    private static let rowPointSize: Double = 28

    private static func backingScale() -> CGFloat {
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    }

    /// The icon to draw for `target`, or `nil` to fall back to the system
    /// icon. A dictionary lookup; a miss warms in the background and
    /// reports through `onIconsResolved`.
    func icon(for target: IconTarget) -> NSImage? {
        resolver.icon(for: target)
    }

    /// Plugging in a sharper display makes every cached icon too soft for
    /// it, and nothing else here would notice. `update(_:)` compares
    /// before acting, so an irrelevant display change costs a comparison.
    private func watchScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resolver.update(.plain(pointSize: Self.rowPointSize,
                                         scale: Self.backingScale()))
        }
    }

    /// Re-reads the store when another app changes it — set an icon in
    /// Pict and it appears in the launcher, not at the next launch.
    private func watch() {
        watcher = IconStoreWatcher(store: store) { [weak self] in
            // Both, and in this order (the Jetty idiom): `invalidate()`
            // schedules the re-render; the hook drops the panel's cached
            // accents now, which is what a *removed* icon needs — it
            // resolves to the system icon, lands no artwork, and so never
            // reaches `onIconsResolved` to be corrected later.
            self?.resolver.invalidate()
            self?.onIconsInvalidated?()
        }
        watcher?.start()
    }
}

extension Item.Icon {

    /// The shared-store lookup target for this icon, or `nil` for an SF
    /// Symbol, which names no thing on disk.
    ///
    /// An app row is an `.application` target so it gets the two-rung
    /// lookup — bundle path first, identifier second — which is what keeps
    /// site-specific-browser wrappers, all reporting one identifier, told
    /// apart. File rows are `.file` targets: a user-set icon for that exact
    /// path still wins, and everything else resolves to the system icon.
    var pictTarget: IconTarget? {
        switch self {
        case .symbol:
            return nil
        case .fileURL(let url):
            return .file(url)
        case .appIcon(let path, let bundleID):
            return .application(bundleURL: URL(fileURLWithPath: path),
                                bundleIdentifier: bundleID)
        }
    }

    /// The on-disk path the workspace icon comes from — the fallback when
    /// the store has nothing, and the accent cache's identity for the
    /// artwork the row actually drew.
    var backingPath: String? {
        switch self {
        case .symbol: return nil
        case .fileURL(let url): return url.path
        case .appIcon(let path, _): return path
        }
    }
}
