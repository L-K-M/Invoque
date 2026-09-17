import AppKit

/// Sets up the status-bar item, the launcher panel and its summon hotkey,
/// and the settings window.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences = Preferences.shared
    private lazy var settingsWindow = SettingsWindowController(preferences: preferences)
    private lazy var panelController = PanelController(preferences: preferences)

    private var statusItem: NSStatusItem?

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

        let settingsItem = NSMenuItem(title: "Invoque Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

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

    /// (Re-)registers the hotkey for the current preference. Replaces any
    /// previous registration — replacing the `CarbonHotkey` unregisters it in
    /// its deinit — so a settings change takes effect immediately.
    private func registerSummonHotkey() {
        let combination = preferences.summonHotkey
        let hotkey = CarbonHotkey(identifier: Self.summonHotkeyID)
        hotkey.onPressed = { [weak self] in self?.panelController.toggle() }
        guard hotkey.register(keyCode: combination.keyCode, modifiers: combination.modifiers) else {
            // CarbonHotkey logged the failure; drop the reference so a later
            // preference change can try again from a clean state.
            summonHotkey = nil
            return
        }
        summonHotkey = hotkey
    }

    // MARK: Helpers

    static var isRunningTests: Bool {
        TestEnvironment.isRunningTests
    }
}
