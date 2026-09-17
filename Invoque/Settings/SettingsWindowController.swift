import AppKit
import SwiftUI

/// Hosts the SwiftUI `SettingsView` in a standard titled window. Used instead of
/// the SwiftUI `Settings` scene so the agent app can present it on demand on
/// macOS 13+ while remaining an accessory app.
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(preferences: preferences))
            // Only let the SwiftUI content drive the window's *minimum* size; the
            // user is free to make it larger.
            hosting.sizingOptions = [.minSize]

            let window = NSWindow(contentViewController: hosting)
            window.title = "Invoque Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 520, height: 460))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            // Set the autosave name last so a previously-saved frame, if any, wins
            // over the centered default position.
            window.setFrameAutosaveName("InvoqueSettingsWindow")
            self.window = window
        }

        // An accessory app's window doesn't take focus on its own; ask for it.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
