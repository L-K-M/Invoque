import AppKit

/// Activates other applications and brings Invoque itself forward for its own
/// windows — the activation half of Zap's `WindowEnumerator`, ported without
/// the AX window enumeration Invoque doesn't need.
///
/// Two consumers: `ActivationHandoff` (returns focus to the last external app
/// after an alert or the Settings window closes) and `UpdateChecker`/`Settings`-
/// `WindowController` (a menu-bar agent must ask for activation before its own
/// UI can take focus).
enum AppActivator {

    /// Cancels verification belonging to an older activation request. Every
    /// activation path and workspace activation notification runs on the main
    /// thread, so a simple generation is enough.
    private static var activationGeneration = 0
    private static var activationObserver: NSObjectProtocol?

    /// Activates `app`, correctly handing activation over from Invoque. macOS 14's
    /// cooperative activation requires the active app to yield before the target
    /// requests activation.
    @discardableResult
    static func activate(_ app: NSRunningApplication, allWindows: Bool = false) -> Bool {
        ensureActivationObserver()
        activationGeneration &+= 1
        let generation = activationGeneration
        let originPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let activated = requestActivation(of: app, allWindows: allWindows)
        if activated {
            verifyActivation(of: app, allWindows: allWindows, remainingRetries: 2,
                             originPID: originPID, generation: generation)
        }
        return activated
    }

    @discardableResult
    private static func requestActivation(of app: NSRunningApplication, allWindows: Bool) -> Bool {
        if #available(macOS 14.0, *) {
            var options: NSApplication.ActivationOptions = []
            if allWindows { options.insert(.activateAllWindows) }
            NSApp.yieldActivation(to: app)
            return app.activate(options: options)
        } else {
            var options: NSApplication.ActivationOptions = [.activateIgnoringOtherApps]
            if allWindows { options.insert(.activateAllWindows) }
            return app.activate(options: options)
        }
    }

    /// Brings Invoque forward to show a window of its own. Unhiding remains
    /// necessary when the user explicitly chose the standard Hide command.
    static func activateSelfForOwnWindow() {
        ensureActivationObserver()
        activationGeneration &+= 1
        // New Invoque UI taking focus must cancel any pending post-restore
        // resignation — otherwise a handoff that restored moments ago would
        // deactivate this window out from under the user.
        ActivationHandoff.cancelPendingResignation()
        if NSApp.isHidden { NSApp.unhide(nil) }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// User-driven activations do not pass through this type. Observe them so a
    /// delayed verification can never mistake a deliberate return to the request's
    /// origin for a failed activation and yank the user back to the old target.
    private static func ensureActivationObserver() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            activationGeneration &+= 1
        }
    }

    /// Pure retry rule: retry only if this is still the newest request and the
    /// frontmost application has not changed since it was made.
    static func shouldRetryActivation(frontmostPID: pid_t?, targetPID: pid_t,
                                      originPID: pid_t?, requestGeneration: Int,
                                      currentGeneration: Int) -> Bool {
        requestGeneration == currentGeneration
            && frontmostPID != targetPID
            && frontmostPID == originPID
    }

    private static func verifyActivation(of app: NSRunningApplication, allWindows: Bool,
                                         remainingRetries: Int, originPID: pid_t?,
                                         generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard !app.isTerminated else { return }
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard shouldRetryActivation(frontmostPID: frontmostPID,
                                        targetPID: app.processIdentifier,
                                        originPID: originPID,
                                        requestGeneration: generation,
                                        currentGeneration: activationGeneration) else { return }

            guard remainingRetries > 0 else {
                // A request can return true without ever taking focus. If Invoque is
                // still the active source, resign so it cannot remain invisibly in
                // front after its own UI closes.
                if NSApp.isActive { NSApp.deactivate() }
                return
            }

            guard requestActivation(of: app, allWindows: allWindows) else {
                if NSApp.isActive { NSApp.deactivate() }
                return
            }
            verifyActivation(of: app, allWindows: allWindows,
                             remainingRetries: remainingRetries - 1,
                             originPID: originPID, generation: generation)
        }
    }
}
