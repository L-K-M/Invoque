import XCTest
@testable import Invoque

/// `DirectoryWatcher` drives `AppSource`'s mid-session rescans — a missed
/// event means an app installed after launch never appears.
final class DirectoryWatcherTests: XCTestCase {

    /// A scratch directory per test, cleaned up on teardown.
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
    }

    /// Creating a file inside a watched root fires the debounced callback.
    func testFiresOnChildCreation() throws {
        let fired = expectation(description: "watcher fired")
        let watcher = DirectoryWatcher(roots: [scratch], debounce: 0.05) {
            fired.fulfill()
        }
        watcher.start()
        XCTAssertTrue(waitFor { watcher.watchedCount > 0 }, "never watched")

        try "x".write(to: scratch.appendingPathComponent("new.txt"),
                      atomically: true, encoding: .utf8)
        wait(for: [fired], timeout: 5)
        watcher.stop()
    }

    /// A directory created by an earlier burst is itself watched by the
    /// rebuild that burst triggers — nested installs under it still fire.
    func testWatchesDirectoriesCreatedByEvents() throws {
        var fires = 0
        let lock = NSLock()
        let second = expectation(description: "second event fired")
        let watcher = DirectoryWatcher(roots: [scratch], debounce: 0.05) {
            lock.lock()
            fires += 1
            if fires == 2 { second.fulfill() }
            lock.unlock()
        }
        watcher.start()
        XCTAssertTrue(waitFor { watcher.watchedCount > 0 }, "never watched")

        let nested = scratch.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        XCTAssertTrue(waitFor { watcher.watchedCount > 1 },
                      "new directory was not added to the watch set")

        try "x".write(to: nested.appendingPathComponent("deep.txt"),
                      atomically: true, encoding: .utf8)
        wait(for: [second], timeout: 5)
        watcher.stop()
    }

    /// A root that does not exist yet is represented by its nearest
    /// existing ancestor, so creating the root later still fires.
    func testMissingRootWatchesAncestor() throws {
        let root = scratch.appendingPathComponent("NotThereYet", isDirectory: true)
        let fired = expectation(description: "watcher fired")
        let watcher = DirectoryWatcher(roots: [root], debounce: 0.05) {
            fired.fulfill()
        }
        watcher.start()
        XCTAssertTrue(waitFor { watcher.watchedCount > 0 },
                      "missing root left nothing watched")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        wait(for: [fired], timeout: 5)
        watcher.stop()
    }

    /// Events outside the roots must not fire — the watcher would rescan
    /// on every unrelated filesystem write otherwise.
    func testIgnoresUnrelatedDirectories() throws {
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }

        let fired = expectation(description: "no event")
        fired.isInverted = true
        let watcher = DirectoryWatcher(roots: [scratch], debounce: 0.05) {
            fired.fulfill()
        }
        watcher.start()
        XCTAssertTrue(waitFor { watcher.watchedCount > 0 }, "never watched")

        try "x".write(to: other.appendingPathComponent("unrelated.txt"),
                      atomically: true, encoding: .utf8)
        wait(for: [fired], timeout: 1.5)
        watcher.stop()
    }

    /// Polls `condition` on the run loop — filesystem events and debounce
    /// timers are asynchronous, so sleeps would just be slower and flakier.
    private func waitFor(_ condition: @escaping () -> Bool,
                         timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
