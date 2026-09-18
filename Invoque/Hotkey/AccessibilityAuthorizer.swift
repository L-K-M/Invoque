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

    /// Prompts the user to grant Accessibility access (shows the system dialog
    /// the first time). Returns the current trust state.
    @discardableResult
    static func prompt() -> Bool {
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
