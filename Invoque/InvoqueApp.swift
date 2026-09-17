import AppKit

/// Program entry point.
///
/// Invoque is a menu-bar agent (`LSUIElement`), so it runs as an `.accessory`
/// app with no Dock icon and never appears in launchers or the app switcher. A
/// plain `NSApplication` lifecycle (rather than the SwiftUI `App` scene) keeps
/// full control over windowing on macOS 13+ — same approach as Zap.
@main
enum InvoqueMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // `NSApplication.delegate` is weak: keep the delegate alive for the
        // whole run loop. In -O builds ARC may otherwise release it after the
        // assignment, taking the status item and menu targets with it.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
