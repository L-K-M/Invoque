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
        static let summonHotkey = HotkeyCombination.default
    }

    private enum Key {
        static let launchAtLogin = "launchAtLogin"
        static let keepQueryOnReshow = "keepQueryOnReshow"
        static let summonHotkey = "summonHotkey"
    }

    // MARK: Stored settings

    /// Whether the panel keeps its previous query when summoned again, rather
    /// than starting empty.
    @Published var keepQueryOnReshow: Bool {
        didSet { defaults.set(keepQueryOnReshow, forKey: Key.keepQueryOnReshow) }
    }

    /// The global hotkey that summons the launcher panel. Persisted as one
    /// `Codable` value (JSON in UserDefaults) so key code and modifiers can't
    /// drift apart — plain defaults can't hold a struct.
    @Published var summonHotkey: HotkeyCombination {
        didSet {
            guard oldValue != summonHotkey else { return }
            persistSummonHotkey()
            summonHotkeyChanged?(summonHotkey)
        }
    }

    /// Tells the Carbon registration's owner to re-register after a change;
    /// Preferences itself stays free of hotkey machinery. DidSet timing, so
    /// it fires after the new value is persisted (note: `@Published`
    /// subscribers are notified earlier, in willSet).
    var summonHotkeyChanged: ((HotkeyCombination) -> Void)?

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin else { return }
            // Persist as a fallback: init seeds from the authoritative
            // SMAppService state, but that read can fail (unsigned/test
            // contexts) and the stored value keeps the intent.
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        keepQueryOnReshow = defaults.object(forKey: Key.keepQueryOnReshow) as? Bool
            ?? Default.keepQueryOnReshow

        summonHotkey = Self.loadSummonHotkey(from: defaults)

        // Seed launch-at-login from the authoritative system state rather than a
        // possibly-stale stored value, so an external change in System Settings is
        // reflected in the UI.
        launchAtLogin = Self.systemLaunchAtLoginEnabled()
            ?? (defaults.object(forKey: Key.launchAtLogin) as? Bool ?? Default.launchAtLogin)
    }

    // MARK: Summon hotkey

    private func persistSummonHotkey() {
        // Two UInt32s can't realistically fail to encode; dropping the write
        // on failure just means the default returns next launch.
        guard let data = try? JSONEncoder().encode(summonHotkey) else { return }
        defaults.set(data, forKey: Key.summonHotkey)
    }

    /// Unreadable or missing stored data falls back to the default — a
    /// hand-edited defaults value must not brick summoning. A decoded value
    /// with no modifiers is rejected too: `RegisterEventHotKey` accepts a
    /// bare key, so `kVK_Space` + 0 would summon the panel on every space
    /// press system-wide.
    private static func loadSummonHotkey(from defaults: UserDefaults) -> HotkeyCombination {
        guard let data = defaults.data(forKey: Key.summonHotkey),
              let combination = try? JSONDecoder().decode(HotkeyCombination.self, from: data),
              combination.modifiers != 0
        else { return Default.summonHotkey }
        return combination
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
