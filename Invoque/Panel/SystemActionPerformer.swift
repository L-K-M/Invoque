import AppKit

/// Performs the fixed macOS actions `SystemSource` offers.
///
/// Restart and shut down go through `osascript` System Events — the first
/// run triggers macOS's Automation consent prompt, which is the sanctioned
/// TCC path; `shutdown(8)`/`reboot(8)` would need root instead. Empty Trash
/// uses FileManager directly on `~/.Trash`, so it needs no consent at all.
enum SystemActionPerformer {

    static func perform(_ action: Item.SystemAction) {
        switch action {
        case .lockScreen:
            // The same lock path ⌃⌘Q takes: fast user-switch to the login
            // window. Ships with macOS and needs no permission prompt.
            run("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
                arguments: ["-suspend"], failureMessage: "Couldn't lock the screen")
        case .sleep:
            run("/usr/bin/pmset", arguments: ["sleepnow"],
                failureMessage: "Couldn't sleep the Mac")
        case .restart:
            appleScript("tell application \"System Events\" to restart",
                        failureMessage: "Restart was denied or failed")
        case .shutDown:
            appleScript("tell application \"System Events\" to shut down",
                        failureMessage: "Shut down was denied or failed")
        case .emptyTrash:
            emptyTrash()
        }
    }

    // MARK: Helpers

    /// `Process` rather than `NSAppleScript`: the script text is a compile-
    /// time constant, so there is nothing to build, and Process reports the
    /// exit status for the log line. `failureMessage` is the HUD text when
    /// the process exits non-zero or cannot launch — a denied Automation
    /// consent must not no-op silently.
    private static func appleScript(_ source: String, failureMessage: String) {
        run("/usr/bin/osascript", arguments: ["-e", source],
            failureMessage: failureMessage)
    }

    private static func run(_ path: String, arguments: [String],
                            failureMessage: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                NSLog("Invoque: system action %@ exited with status %d",
                      path, Int(process.terminationStatus))
                HUD.show(failureMessage)
            }
        }
        do {
            try process.run()
        } catch {
            NSLog("Invoque: system action failed to launch %@: %@", path, error.localizedDescription)
            HUD.show(failureMessage)
        }
    }

    /// Empties the boot volume's Trash directly — Finder's "Empty Trash"
    /// AppleEvent would cost an Automation consent prompt. Runs off the
    /// calling thread: a Trash with thousands of entries would stall the
    /// UI, and the outcome HUD replaces per-item log lines the user could
    /// never see. Entries that can't be removed (in use, permissions) are
    /// logged and left behind.
    private static func emptyTrash() {
        DispatchQueue.global(qos: .utility).async {
            let trash = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash", isDirectory: true)
            // A fresh account may have no ~/.Trash at all — that is an
            // empty Trash, not a read failure.
            guard FileManager.default.fileExists(atPath: trash.path) else {
                HUD.show("Trash emptied")
                return
            }
            guard let failures = emptyTrashContents(at: trash) else {
                HUD.show("Couldn't read the Trash")
                return
            }
            HUD.show(failures == 0 ? "Trash emptied"
                     : "Couldn't remove \(failures) item\(failures == 1 ? "" : "s")")
        }
    }

    /// The removal half of Empty Trash, extracted for tests: deletes every
    /// entry directly inside `trash` and returns the count that could not
    /// be removed — `nil` when the directory can't be read at all.
    static func emptyTrashContents(at trash: URL) -> Int? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: trash,
            includingPropertiesForKeys: nil,
            options: []) else { return nil }
        var failures = 0
        for item in contents {
            do {
                try FileManager.default.removeItem(at: item)
            } catch {
                // Finder or a second Empty Trash may have removed it
                // first — a vanished entry is not a failure.
                if !FileManager.default.fileExists(atPath: item.path) {
                    continue
                }
                failures += 1
                NSLog("Invoque: could not remove %@ from Trash: %@",
                      item.lastPathComponent, error.localizedDescription)
            }
        }
        return failures
    }
}
