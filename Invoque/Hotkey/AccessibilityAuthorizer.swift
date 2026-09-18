import ApplicationServices
import AppKit

/// Thin wrapper around the Accessibility (AX) trust APIs that gate simulated
/// keystrokes (`invoque.paste`). Copied from Zap — same maintainer, same
/// conventions.
enum AccessibilityAuthorizer {

    /// Whether the process is currently trusted for Accessibility.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Whether `prompt()` has already run this session. The system alert
    /// only appears on the first call — later calls are silently denied, so
    /// a caller can read this *before* prompting to know whether the user
    /// will see a dialog or whether opening Settings itself is the only
    /// prompt they'll get. Lock-guarded: today's reader/writer pair is the
    /// JS queue, but a main-thread call site would otherwise race it.
    static var hasPrompted: Bool {
        hasPromptedLock.lock()
        defer { hasPromptedLock.unlock() }
        return _hasPrompted
    }
    private static let hasPromptedLock = NSLock()
    private static var _hasPrompted = false

    /// Prompts the user to grant Accessibility access (shows the system dialog
    /// the first time). Returns the current trust state.
    @discardableResult
    static func prompt() -> Bool {
        hasPromptedLock.lock()
        _hasPrompted = true
        hasPromptedLock.unlock()
        // Value of `kAXTrustedCheckOptionPrompt`; used as a literal to avoid
        // cross-SDK differences in how that symbol is imported into Swift.
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens the Accessibility pane in System Settings. The
    /// `PrivacySecurity.extension` anchor is the canonical Ventura+ target —
    /// the pre-Ventura `com.apple.preference.security` URL only survives via
    /// a compatibility redirect.
    static func openSystemSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
