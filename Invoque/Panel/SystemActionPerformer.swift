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
                arguments: ["-suspend"])
        case .sleep:
            run("/usr/bin/pmset", arguments: ["sleepnow"])
        case .restart:
            appleScript("tell application \"System Events\" to restart")
        case .shutDown:
            appleScript("tell application \"System Events\" to shut down")
        case .emptyTrash:
            emptyTrash()
        }
    }

    // MARK: Helpers

    /// `Process` rather than `NSAppleScript`: the script text is a compile-
    /// time constant, so there is nothing to build, and Process reports the
    /// exit status for the log line.
    private static func appleScript(_ source: String) {
        run("/usr/bin/osascript", arguments: ["-e", source])
    }

    private static func run(_ path: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // A denied Automation consent exits osascript non-zero — without
        // this the restart/shutdown no-ops with zero feedback anywhere.
        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                NSLog("Invoque: system action %@ exited with status %d",
                      path, Int(process.terminationStatus))
            }
        }
        do {
            try process.run()
        } catch {
            NSLog("Invoque: system action failed to launch %@: %@", path, error.localizedDescription)
        }
    }

    /// Empties the boot volume's Trash directly — Finder's "Empty Trash"
    /// AppleEvent would cost an Automation consent prompt. Entries that
    /// can't be removed (in use, permissions) are logged and left behind.
    private static func emptyTrash() {
        let trash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: trash,
            includingPropertiesForKeys: nil,
            options: []) else { return }
        for item in contents {
            do {
                try FileManager.default.removeItem(at: item)
            } catch {
                NSLog("Invoque: could not remove %@ from Trash: %@",
                      item.lastPathComponent, error.localizedDescription)
            }
        }
    }
}
