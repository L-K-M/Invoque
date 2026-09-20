import AppKit

/// Sets up the status-bar item, the launcher panel and its summon hotkey,
/// and the settings window.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences = Preferences.shared
    private let updateChecker = UpdateChecker(
        configuration: .init(owner: "L-K-M", repo: "Invoque", appName: "Invoque")
    )
    private lazy var settingsWindow = SettingsWindowController(preferences: preferences,
                                                               updateChecker: updateChecker)
    private lazy var panelController = Self.makePanelController(preferences: preferences)

    private var statusItem: NSStatusItem?
    /// Hidden until a background check queues an update — then it names the
    /// pending release and presents its alert on click.
    private var updateMenuItem: NSMenuItem?

    /// Identifies the summon hotkey to Carbon; any value unique within the app works.
    private static let summonHotkeyID: UInt32 = 1
    private var summonHotkey: CarbonHotkey?

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Don't install global hooks or UI while running under XCTest.
        guard !Self.isRunningTests else { return }

        // Before anything can put a window up: without a main menu the standard
        // editing shortcuts don't exist, because that is where they live.
        MainMenu.install(into: NSApplication.shared)
        setUpStatusItem()
        setUpSummonHotkey()
        // A background check that finds an update while the app is inactive
        // queues it — the menu item is its discoverable surface until the
        // alert can present without stealing focus.
        updateChecker.onPendingUpdateChanged = { [weak self] tag in
            guard let item = self?.updateMenuItem else { return }
            item.isHidden = tag == nil
            if let tag { item.title = "Update Available: \(tag)" }
        }
        updateChecker.start()   // check GitHub for a newer release on launch + daily
    }

    // MARK: Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.statusBarImage()
        item.menu = buildMenu()
        statusItem = item
    }

    /// The menu-bar icon: the `command.bubble` glyph, rendered as a template
    /// image so the system tints it for light/dark menu bars automatically.
    /// `command.bubble` is SF Symbols 5 (macOS 14+); on older systems the
    /// lookup returns nil, so fall back to `text.bubble` (SF Symbols 1) —
    /// an empty image would render the status item invisible.
    static func statusBarImage() -> NSImage {
        let image = NSImage(systemSymbolName: "command.bubble",
                            accessibilityDescription: "Invoque")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            ?? NSImage(systemSymbolName: "text.bubble",
                       accessibilityDescription: "Invoque")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            ?? NSImage()
        image.isTemplate = true
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open Invoque", action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let pendingItem = NSMenuItem(title: "", action: #selector(showPendingUpdate), keyEquivalent: "")
        pendingItem.target = self
        pendingItem.isHidden = true
        menu.addItem(pendingItem)
        updateMenuItem = pendingItem

        let settingsItem = NSMenuItem(title: "Invoque Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Invoque", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: Actions

    /// Not private: `MainMenu` names this selector, and the menu item reaches it
    /// through the responder chain rather than a target of its own.
    @objc func openSettings() {
        settingsWindow.show()
    }

    @objc private func openPanel() {
        panelController.show()
    }

    @objc private func checkForUpdates() {
        updateChecker.checkNow()
    }

    @objc private func showPendingUpdate() {
        updateChecker.presentPendingUpdateNow()
    }

    /// Assembles the search stack and its owner. `model` is built first so
    /// `AppSource.onReload` can re-run the open query — the hook must be
    /// passed at init (a post-init assignment can miss the first scan).
    private static func makePanelController(preferences: Preferences) -> PanelController {
        let model = PanelModel()
        let commandStore = CommandStore()
        commandStore.startWatching()
        // autoReload off: the initial scan must not fire onChange before
        // onReload is wired — wire first, then kick the scan explicitly.
        let commandSource = CommandSource(store: commandStore, autoReload: false)
        commandSource.onReload = { [weak model] in model?.refreshResults() }
        let commandRunner = CommandRunner()
        model.commandRunner = commandRunner
        model.filterLookup = { [commandSource] keyword in
            commandSource.filterCommand(forKeyword: keyword)
        }
        model.commandLookup = { [commandStore] name in
            commandStore.command(named: name)
        }
        // First-run consent for risky permissions — one store shared by the
        // panel's run path and the Maker's test path, so Allow once covers
        // both (PLAN §4.3).
        let permissionGrants = CommandPermissionGrants()
        // The Maker: `make `/`mk ` routes to it. The client is a factory so
        // each generation picks up the current Settings (model/key changes
        // apply without a relaunch).
        model.maker = MakerModel(
            client: { MakerSettings.shared.makeClient() },
            runner: commandRunner,
            // The writer saves into the same root the store scans — a saved
            // command is visible to the launcher immediately.
            writer: CommandWriter(rootURL: commandStore.primaryRootURL),
            store: commandStore,
            permissionGrants: permissionGrants)
        // `find `/`f ` — the Spotlight-free filename walk (PLAN §3). The
        // scan runs inside the model's debounced task; the probe lets
        // `cancelFileSearch` reach a walk mid-flight.
        model.fileSearcher = { query, isCancelled in
            FileSearch.items(query: query, isCancelled: isCancelled)
        }
        // Shared icon store (PictKit) — the same ladder Zap and Jetty draw
        // from: a Pict override, then the bundle's own un-jailed artwork,
        // then the workspace icon on a miss. The hook republishes when
        // artwork lands or another app rewrites the store.
        model.iconResolver = { InvoqueIcons.shared.icon(for: $0) }
        InvoqueIcons.shared.onIconsInvalidated = { [weak model] in
            model?.noteIconsChanged()
        }
        // Kick the initial scan only after the model is fully wired — an
        // unstructured Task starts immediately and can outrun the lines
        // above. (The store's onChange→onReload subscription is init-time,
        // so commands installed later still refresh the open panel.)
        Task { await commandSource.reload() }
        // One rules facade shared by the ranker and the panel: the panel's
        // toggles write through to Preferences, and the ranker reads the
        // same state when it assembles each query's list.
        let entryRules = EntryRules(
            isPinned: { [weak preferences] in preferences?.isPinned($0) ?? false },
            isBlocked: { [weak preferences] in preferences?.isBlocked($0) ?? false },
            togglePin: { [weak preferences] in
                preferences?.togglePinned(id: $0, title: $1) ?? false },
            toggleBlock: { [weak preferences] in
                preferences?.toggleBlocked(id: $0, title: $1) ?? false })
        model.entryRules = entryRules
        // A pin/block made in Settings must repaint the open panel; the
        // panel's own toggles reach it through this path too.
        preferences.entryRulesChanged = { [weak model] in
            model?.entryRulesDidChange()
        }
        let sources: [ItemSource] = [
            PathSource(),
            AppSource(onReload: { [weak model] in model?.refreshResults() }),
            commandSource,
            CalculatorSource(),
            SystemSource(),
            WebSource(engine: { [weak preferences] in
                preferences?.searchEngine ?? .duckDuckGo
            }),
        ]
        let searchModel = SearchModel(sources: sources, frecency: Frecency(),
                                      entryRules: entryRules)
        return PanelController(preferences: preferences, model: model,
                               searchModel: searchModel,
                               commandStore: commandStore,
                               commandRunner: commandRunner,
                               permissionGrants: permissionGrants)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Summon hotkey

    private func setUpSummonHotkey() {
        preferences.summonHotkeyChanged = { [weak self] _ in
            self?.registerSummonHotkey()
        }
        registerSummonHotkey()
    }

    /// The combination that is actually registered right now — the fallback
    /// a failed re-registration reverts the preference to.
    private var registeredCombination: HotkeyCombination?

    /// (Re-)registers the hotkey for the current preference. Replaces any
    /// previous registration — replacing the `CarbonHotkey` unregisters it in
    /// its deinit — so a settings change takes effect immediately.
    private func registerSummonHotkey() {
        let combination = preferences.summonHotkey
        let hotkey = CarbonHotkey(identifier: Self.summonHotkeyID)
        hotkey.onPressed = { [weak self] in self?.panelController.toggle() }
        guard hotkey.register(keyCode: combination.keyCode, modifiers: combination.modifiers) else {
            // CarbonHotkey logged the failure; keep the previous working
            // registration — a conflicting chord must not leave the app
            // without any summon hotkey. Revert the stored preference to the
            // chord that is still registered so the next launch re-registers
            // it instead of retrying the conflict and coming up hotkey-less.
            // The revert fires summonHotkeyChanged, which re-enters here and
            // converges: re-registering the live chord either succeeds or is
            // already-held (`eventHotKeyExistsErr`), and the preference is
            // already the revert target so no further revert happens.
            let fallback = registeredCombination ?? .default
            if preferences.summonHotkey != fallback {
                // TODO(settings UI): surface this revert (e.g. a
                // `summonHotkeyRegistrationFailed` flag on Preferences) so a
                // conflicting chord isn't discarded without feedback.
                preferences.summonHotkey = fallback
            }
            return
        }
        registeredCombination = combination
        summonHotkey = hotkey
    }

    // MARK: Helpers

    static var isRunningTests: Bool {
        TestEnvironment.isRunningTests
    }
}
