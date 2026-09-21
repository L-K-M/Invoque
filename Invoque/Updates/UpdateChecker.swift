import AppKit

/// Drop-in "is there a newer release on GitHub?" checker — ported from Zap.
///
/// Configure it with a repository and call `start()` once at launch: it checks on
/// startup and then daily — throttled by a stored last-check date so relaunches
/// don't spam — and shows an AppKit alert offering **Download**, **Remind Me
/// Later**, or **Skip This Version** when a newer release exists. `checkNow()`
/// is the user-initiated path (ignores the throttle and also reports "you're up
/// to date" and errors).
///
/// Self-contained and reusable across apps: it owns its small state (enabled
/// flag, skipped version, last-check date) in `UserDefaults` under namespaced
/// keys. Depends on AppKit + Foundation plus `AppActivator`/`ActivationHandoff`
/// for the alert presentation.
///
/// Main-confined by contract: every caller is main-affine (status-menu
/// actions, the main-run-loop `Timer`, SwiftUI, `.main` notification
/// delivery), and `@Sendable` hops only ever carry the reference *to* the
/// main actor — that confinement is what `Sendable` asserts.
final class UpdateChecker: ObservableObject, @unchecked Sendable {

    /// The one call the checker needs — seams the network for tests.
    protocol ReleaseFetching {
        func latestRelease(includePrereleases: Bool) async throws -> GitHubRelease
    }

    struct Configuration {
        var owner: String
        var repo: String
        var appName: String
        var currentVersion: String
        var allowPrereleases: Bool
        /// When true (default), the alert's **Download** action saves the release's
        /// disk image/zip to `~/Downloads` and reveals it in Finder; when false it
        /// just opens the release page in the browser.
        var autoDownloadAssets: Bool
        var minimumCheckInterval: TimeInterval
        /// Namespacing prefix for this checker's `UserDefaults` keys.
        var defaultsKeyPrefix: String

        init(owner: String,
             repo: String,
             appName: String = Bundle.main.appDisplayName,
             currentVersion: String = Bundle.main.shortVersionString,
             allowPrereleases: Bool = false,
             autoDownloadAssets: Bool = true,
             minimumCheckInterval: TimeInterval = 24 * 60 * 60,
             defaultsKeyPrefix: String? = nil) {
            self.owner = owner
            self.repo = repo
            self.appName = appName
            self.currentVersion = currentVersion
            self.allowPrereleases = allowPrereleases
            self.autoDownloadAssets = autoDownloadAssets
            self.minimumCheckInterval = minimumCheckInterval
            self.defaultsKeyPrefix = defaultsKeyPrefix ?? "UpdateChecker.\(owner).\(repo)"
        }
    }

    let configuration: Configuration
    private let client: any ReleaseFetching
    private let downloader = UpdateDownloader()
    private let defaults: UserDefaults
    private var timer: Timer?

    /// A newer release found by a background check while Invoque was inactive —
    /// a menu-bar agent must never steal focus for an update prompt, so it is
    /// surfaced on the status menu immediately and presented the next time the
    /// app legitimately owns focus.
    private var pendingUpdate: GitHubRelease?
    private var activationObserver: NSObjectProtocol?

    /// A `checkNow()` that arrives while a check is already in flight reports
    /// that run's outcome as user-initiated rather than being dropped.
    private var pendingUserInitiatedCheck = false

    /// Called when `pendingUpdate` changes (tag name, or nil once presented).
    /// `AppDelegate` mirrors it onto a status-menu item so a queued update is
    /// still discoverable while the app is inactive.
    var onPendingUpdateChanged: ((String?) -> Void)?

    /// Whether to check automatically (on launch and daily). User-facing toggle.
    @Published var automaticChecksEnabled: Bool {
        didSet {
            defaults.set(automaticChecksEnabled, forKey: key("enabled"))
            if automaticChecksEnabled, !oldValue { checkInBackground() }
        }
    }

    /// When the last successful check completed (for a Settings "last checked" line).
    @Published private(set) var lastCheckDate: Date?

    /// True while a check is in flight (to disable a "Check Now" button, say).
    @Published private(set) var isChecking = false

    /// True while an update asset is downloading to `~/Downloads`.
    @Published private(set) var isDownloading = false

    init(configuration: Configuration, defaults: UserDefaults = .standard,
         client: (any ReleaseFetching)? = nil) {
        self.configuration = configuration
        self.defaults = defaults
        self.client = client ?? GitHubReleaseClient(owner: configuration.owner,
                                                  repo: configuration.repo)
        let prefix = configuration.defaultsKeyPrefix
        // Default ON unless the user has explicitly turned it off.
        self.automaticChecksEnabled = defaults.object(forKey: "\(prefix).enabled") as? Bool ?? true
        self.lastCheckDate = defaults.object(forKey: "\(prefix).lastCheck") as? Date
    }

    deinit {
        timer?.invalidate()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    // MARK: Public API

    /// Begins automatic checking: an immediate (throttled) check plus a daily timer.
    /// Call once at launch. No-op under XCTest.
    func start() {
        guard !TestEnvironment.isRunningTests else { return }
        // A second start() must not leave the old timer scheduled forever.
        timer?.invalidate()
        checkInBackground()
        let interval = configuration.minimumCheckInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkInBackground()
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Runs a check only if automatic checks are on and the throttle interval has
    /// elapsed. Silent unless a newer, non-skipped version is found.
    func checkInBackground() {
        guard automaticChecksEnabled else { return }
        if let last = lastCheckDate, Date().timeIntervalSince(last) < configuration.minimumCheckInterval { return }
        performCheck(userInitiated: false)
    }

    /// User-initiated check (menu / Settings): ignores the throttle and always
    /// reports the outcome, including "you're up to date" and errors.
    func checkNow() {
        performCheck(userInitiated: true)
    }

    /// Presents the queued background update immediately — the status-menu
    /// "Update Available" item calls this; an explicit click is a user
    /// initiation, so the alert is appropriate even though the app was inactive.
    func presentPendingUpdateNow() {
        Task { @MainActor in self.presentPendingUpdateIfAny() }
    }

    // MARK: Check

    private var skippedVersion: String? {
        get { defaults.string(forKey: key("skippedVersion")) }
        set { defaults.set(newValue, forKey: key("skippedVersion")) }
    }

    private func performCheck(userInitiated: Bool) {
        guard !isChecking else {
            // A checkNow() during an in-flight run must still report — mark
            // this run's outcome as user-requested rather than dropping it.
            if userInitiated { pendingUserInitiatedCheck = true }
            return
        }
        isChecking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // A checkNow() landing while a result alert is on screen
                // (runModal spins a nested run loop) arrives after this run
                // consumed its flag. It must neither leak into a future
                // automatic check (a stale flag would make it report and
                // steal focus) nor be dropped — run it as its own
                // user-initiated check once this one finishes.
                let queued = self.pendingUserInitiatedCheck
                self.pendingUserInitiatedCheck = false
                self.isChecking = false
                if queued { self.performCheck(userInitiated: true) }
            }
            do {
                let release = try await self.client.latestRelease(
                    includePrereleases: self.configuration.allowPrereleases)
                // Consume after the await: a checkNow() that arrived while this
                // request was in flight must have THIS run's outcome reported —
                // reading the flag earlier would drop the click and leak the
                // flag into a future automatic check.
                let report = userInitiated || self.pendingUserInitiatedCheck
                self.pendingUserInitiatedCheck = false
                self.lastCheckDate = Date()
                self.defaults.set(self.lastCheckDate, forKey: self.key("lastCheck"))

                // "Couldn't determine" is not "you're up to date" — an
                // unparseable version must not assert the user is current,
                // and the alert must blame the string that actually failed.
                guard let remote = SemanticVersion(release.tagName) else {
                    if report { self.presentUnparseable(tag: release.tagName) }
                    return
                }
                guard let current = SemanticVersion(self.configuration.currentVersion) else {
                    if report {
                        self.presentUnparseable(
                            tag: "installed version \(self.configuration.currentVersion)")
                    }
                    return
                }
                if remote > current {
                    // Semantic compare: a retag ("v1.3.0" → "1.3.0") must not
                    // re-prompt a version the user already skipped.
                    let skipped = self.skippedVersion.flatMap(SemanticVersion.init)
                    if report {
                        self.presentUpdateAvailable(release: release, remote: remote, current: current)
                    } else if skipped != remote {
                        if NSApp.isActive {
                            self.presentUpdateAvailable(release: release, remote: remote, current: current)
                        } else {
                            self.queuePendingUpdate(release)
                        }
                    }
                } else if report {
                    self.presentUpToDate()
                }
            } catch {
                // Same consumption on the failure path — a mid-flight click
                // must surface this error, not seed a later automatic check.
                let report = userInitiated || self.pendingUserInitiatedCheck
                self.pendingUserInitiatedCheck = false
                if report { self.presentError(error) }
                else { NSLog("UpdateChecker: background check failed: %@", error.localizedDescription) }
            }
        }
    }

    /// Queues an update found in the background while the app is inactive: the
    /// status menu gets an "Update Available" item now, and the alert itself is
    /// presented the next time Invoque legitimately owns focus — never as a
    /// focus-stealing modal on a timer.
    /// `@MainActor` so `onPendingUpdateChanged` is guaranteed main-thread —
    /// its consumer mutates AppKit menu items.
    @MainActor
    private func queuePendingUpdate(_ release: GitHubRelease) {
        pendingUpdate = release
        onPendingUpdateChanged?(release.tagName)
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.presentPendingUpdateIfAny() }
        }
    }

    @MainActor
    private func presentPendingUpdateIfAny() {
        guard let release = pendingUpdate else { return }
        // Validate before clearing — a queued tag can't fail this (queueing
        // already required a successful parse), but if that ever changes the
        // update must surface as unparseable rather than vanish.
        guard let remote = SemanticVersion(release.tagName),
              let current = SemanticVersion(configuration.currentVersion) else {
            pendingUpdate = nil
            onPendingUpdateChanged?(nil)
            presentUnparseable(tag: release.tagName)
            return
        }
        pendingUpdate = nil
        onPendingUpdateChanged?(nil)
        presentUpdateAvailable(release: release, remote: remote, current: current)
    }

    // MARK: Presentation

    @MainActor
    private func presentUpdateAvailable(release: GitHubRelease, remote: SemanticVersion, current: SemanticVersion) {
        // Presenting a release (e.g. a user-initiated check) retires a queued
        // update that is the same or older — otherwise a stale "Update
        // Available" would resurface on the next activation after the user
        // already saw the newer alert.
        if let pendingRemote = pendingUpdate.flatMap({ SemanticVersion($0.tagName) }),
           pendingRemote <= remote {
            pendingUpdate = nil
            onPendingUpdateChanged?(nil)
        }
        let alert = NSAlert()
        alert.messageText = "A new version of \(configuration.appName) is available"
        var info = "\(configuration.appName) \(remote) is available — you have \(current)."
        if let notes = release.releaseNotes() { info += "\n\n\(notes)" }
        alert.informativeText = info
        alert.addButton(withTitle: "Download")           // .alertFirstButtonReturn
        alert.addButton(withTitle: "Remind Me Later")    // .alertSecondButtonReturn
        alert.addButton(withTitle: "Skip This Version")  // .alertThirdButtonReturn

        switch runModal(alert) {
        case .alertFirstButtonReturn:
            if configuration.autoDownloadAssets {
                downloadAndReveal(release)
            } else {
                NSWorkspace.shared.open(release.htmlURL)
            }
        case .alertThirdButtonReturn:
            skippedVersion = release.tagName
        default:
            break   // Remind Me Later — re-offered on the next check.
        }
    }

    /// Downloads the release's preferred asset to `~/Downloads` and reveals it in
    /// Finder. Falls back to opening the release page if there's no downloadable
    /// asset or the download fails.
    @MainActor
    private func downloadAndReveal(_ release: GitHubRelease) {
        guard let asset = release.preferredAsset else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }
        // A second Download click while a download runs gets the same
        // fallback as every other failure here — never a silent no-op.
        guard !isDownloading else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }
        isDownloading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isDownloading = false }
            do {
                let fileURL = try await self.downloader.downloadToDownloads(asset)
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } catch {
                NSLog("UpdateChecker: download failed (%@); opening release page", error.localizedDescription)
                NSWorkspace.shared.open(release.htmlURL)
            }
        }
    }

    @MainActor
    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "\(configuration.appName) \(configuration.currentVersion) is the latest version."
        alert.addButton(withTitle: "OK")
        _ = runModal(alert)
    }

    /// A release tag the checker couldn't parse — distinct from "up to date",
    /// which would wrongly assert the user is current when the answer is unknown.
    @MainActor
    private func presentUnparseable(tag: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = "The version string (“\(tag)”) couldn't be parsed."
        alert.addButton(withTitle: "OK")
        _ = runModal(alert)
    }

    @MainActor
    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = runModal(alert)
    }

    /// Brings the alert forward before running it modally — a menu-bar agent isn't
    /// the active app, so without this the alert can appear behind other windows
    /// with no Dock icon to click.
    @MainActor
    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        // Under XCTest a real modal would block the run loop forever — answer
        // "Remind Me Later" so check flows can still be exercised end-to-end.
        guard !TestEnvironment.isRunningTests else { return .alertSecondButtonReturn }
        let handoff = ActivationHandoff()
        AppActivator.activateSelfForOwnWindow()
        alert.window.level = .floating
        let response = alert.runModal()
        handoff.restore()
        return response
    }

    // MARK: Helpers

    private func key(_ suffix: String) -> String { "\(configuration.defaultsKeyPrefix).\(suffix)" }
}

extension GitHubReleaseClient: UpdateChecker.ReleaseFetching {}

extension Bundle {
    /// `CFBundleShortVersionString` (the marketing version), or `"0"`.
    var shortVersionString: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// The app's display name, falling back to the bundle name then the process name.
    var appDisplayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }
}
