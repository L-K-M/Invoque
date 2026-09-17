import AppKit

/// Sets up the status-bar item and the settings window.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences = Preferences.shared
    private lazy var settingsWindow = SettingsWindowController(preferences: preferences)

    private var statusItem: NSStatusItem?

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Don't install global hooks or UI while running under XCTest.
        guard !Self.isRunningTests else { return }

        // Before anything can put a window up: without a main menu the standard
        // editing shortcuts don't exist, because that is where they live.
        MainMenu.install(into: NSApplication.shared)
        setUpStatusItem()
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
                       accessibilityDescription: "Invoque")
            ?? NSImage()
        image.isTemplate = true
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

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

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    static var isRunningTests: Bool {
        TestEnvironment.isRunningTests
    }
}
