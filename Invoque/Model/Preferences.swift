import Foundation
import ServiceManagement

/// User-facing settings, backed by `UserDefaults`.
///
/// An `ObservableObject` so SwiftUI settings views update live. A custom
/// `UserDefaults` can be injected for tests.
final class Preferences: ObservableObject {

    static let shared = Preferences()

    private let defaults: UserDefaults

    // MARK: Defaults

    enum Default {
        static let launchAtLogin = false
        static let keepQueryOnReshow = false
    }

    private enum Key {
        static let launchAtLogin = "launchAtLogin"
        static let keepQueryOnReshow = "keepQueryOnReshow"
    }

    // MARK: Stored settings

    /// Whether the panel keeps its previous query when summoned again, rather
    /// than starting empty.
    @Published var keepQueryOnReshow: Bool {
        didSet { defaults.set(keepQueryOnReshow, forKey: Key.keepQueryOnReshow) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        keepQueryOnReshow = defaults.object(forKey: Key.keepQueryOnReshow) as? Bool
            ?? Default.keepQueryOnReshow

        // Seed launch-at-login from the authoritative system state rather than a
        // possibly-stale stored value, so an external change in System Settings is
        // reflected in the UI.
        launchAtLogin = Self.systemLaunchAtLoginEnabled()
            ?? (defaults.object(forKey: Key.launchAtLogin) as? Bool ?? Default.launchAtLogin)
    }

    // MARK: Launch at login

    private var isSyncingLaunchAtLogin = false

    /// Reads the real login-item state. Returns `nil` when the system can't
    /// answer (notably under XCTest, where there is no real app bundle).
    private static func systemLaunchAtLoginEnabled() -> Bool? {
        guard !TestEnvironment.isRunningTests else { return nil }
        return SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        guard !TestEnvironment.isRunningTests else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Invoque: failed to set launch-at-login to \(enabled): \(error)")
            // Re-sync the published value so the toggle reflects reality.
            isSyncingLaunchAtLogin = true
            launchAtLogin = Self.systemLaunchAtLoginEnabled() ?? !enabled
            isSyncingLaunchAtLogin = false
        }
    }
}
