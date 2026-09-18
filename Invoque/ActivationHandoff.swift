import AppKit

/// Returns activation to the last external app after Invoque finishes presenting UI
/// of its own. Tracking the whole presentation avoids restoring a stale app when
/// the user switches elsewhere before closing the window or alert.
///
/// Ported from Zap's `ActivationHandoff` — same role, adapted to `AppActivator`.
final class ActivationHandoff {

    private static let ownPID = NSRunningApplication.current.processIdentifier
    private static var presentationCount = 0
    private static var generation = 0
    private static var target: NSRunningApplication?
    private static var activationObserver: NSObjectProtocol?

    private var isTracking = true

    /// How many Invoque presentations are currently open. For tests: the nesting
    /// rule — only the last one to close hands activation back — is the part of
    /// this type most likely to break silently, and it is otherwise unobservable.
    static var openPresentations: Int { presentationCount }

    init() {
        assert(Thread.isMainThread)
        Self.presentationCount += 1
        Self.generation &+= 1
        if Self.presentationCount == 1 { Self.startObserving() }
    }

    deinit {
        // deinit runs wherever the last reference is released — which Swift
        // does not guarantee is the main thread — while finish() mutates
        // main-thread-confined statics. Keep the count consistent without
        // racing them; an owner dropping its reference off-main is a
        // lifecycle bug this fallback covers rather than fixes.
        guard isTracking else { return }
        if Thread.isMainThread {
            finish(shouldRestore: false)
        } else {
            isTracking = false
            DispatchQueue.main.async { Self.dropDroppedPresentation() }
        }
    }

    /// Counts down a presentation whose owner released it off the main thread.
    /// The decrement is delayed, so the count can transiently overstate.
    private static func dropDroppedPresentation() {
        presentationCount = max(presentationCount - 1, 0)
    }

    /// Ends this presentation. Nested Invoque UI shares the same handoff, so only
    /// the final window or alert to close returns activation to the external app.
    func restore() {
        finish(shouldRestore: true)
    }

    /// Restore only while Invoque still owns activation. A different active app is
    /// a newer user choice and must never be replaced by a stale handoff.
    static func shouldRestore(targetPID: pid_t, targetIsTerminated: Bool,
                              invoqueIsActive: Bool, ownPID: pid_t) -> Bool {
        !targetIsTerminated && targetPID != ownPID && invoqueIsActive
    }

    /// Invalidates the delayed post-restore resignation check so Invoque UI that
    /// takes focus right after a handoff restore keeps it — e.g. a panel summoned
    /// within the 0.25 s window must not be deactivated out from under the user.
    static func cancelPendingResignation() {
        assert(Thread.isMainThread)
        generation &+= 1
    }

    private func finish(shouldRestore: Bool) {
        guard isTracking else { return }
        assert(Thread.isMainThread)
        isTracking = false
        Self.presentationCount -= 1
        guard Self.presentationCount == 0 else { return }

        let target = Self.target

        // `shouldRestore` first, then read `NSApp` once. Ordering matters as well
        // as counting: a presentation dropped without `restore()` must return
        // before touching `NSApp` at all.
        guard shouldRestore else { return }
        let invoqueIsActive = NSApp.isActive
        guard invoqueIsActive else { return }
        guard let target,
              Self.shouldRestore(targetPID: target.processIdentifier,
                                 targetIsTerminated: target.isTerminated,
                                 invoqueIsActive: invoqueIsActive,
                                 ownPID: Self.ownPID) else {
            NSApp.deactivate()
            return
        }

        let generation = Self.generation
        guard AppActivator.activate(target) else {
            NSApp.deactivate()
            return
        }

        // Activation is asynchronous even when the request returns true. If
        // Invoque still owns focus after the request has had time to settle,
        // explicitly resign it; a newly-opened Invoque presentation cancels this
        // fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard Self.presentationCount == 0,
                  Self.generation == generation,
                  NSApp.isActive else { return }
            NSApp.deactivate()
        }
    }

    private static func startObserving() {
        if activationObserver == nil {
            // Keep this observer for the process lifetime. A minimized Settings
            // window has no active handoff, but an app used while it is minimized
            // must still become the target when Settings is restored from the Dock.
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                record(app)
            }
        }
        // Subscribe first, then sample, so an activation cannot fall between the
        // initial snapshot and observer installation.
        record(NSWorkspace.shared.frontmostApplication)
    }

    private static func record(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ownPID else { return }
        target = app
    }
}
