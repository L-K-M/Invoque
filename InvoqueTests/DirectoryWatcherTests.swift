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

    /// Every open failing at start leaves zero live sources — and no
    /// filesystem event can ever arrive to trigger recovery, so the
    /// retry must be self-scheduled: once opens succeed the watcher
    /// comes back on its own.
    func testTotalOpenFailureRetriesWithoutEvents() throws {
        let saved = DirectoryWatcher.retryCooldown
        defer { DirectoryWatcher.retryCooldown = saved }
        DirectoryWatcher.retryCooldown = 0.1

        let gate = OpenGate()
        let watcher = DirectoryWatcher(roots: [scratch], debounce: 0.05) {}
        watcher.canOpenTarget = { _ in gate.isAllowed }
        watcher.start()
        XCTAssertTrue(waitFor { watcher.failedCount > 0 },
                      "failed open never recorded")
        XCTAssertEqual(watcher.liveSourceCount, 0)

        gate.allow()
        XCTAssertTrue(waitFor { watcher.failedCount == 0 },
                      "failed open was never retried")
        XCTAssertEqual(watcher.liveSourceCount, 1)
        watcher.stop()
    }

    /// A permanently failing target retries on the cooldown — not per
    /// event — and never drags the healthy source down with it. The
    /// cooldown is pinned long so no retry lands inside the test: any
    /// second attempt is a throttle regression, not a timing flake.
    func testFailedOpenCooldownKeepsHealthySource() throws {
        let saved = DirectoryWatcher.retryCooldown
        defer { DirectoryWatcher.retryCooldown = saved }
        DirectoryWatcher.retryCooldown = 60

        let failing = scratch.appendingPathComponent("Failing", isDirectory: true)
        let healthy = scratch.appendingPathComponent("Healthy", isDirectory: true)
        try FileManager.default.createDirectory(at: failing,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: healthy,
                                                withIntermediateDirectories: true)

        let attempts = LockedCounter()
        let fires = LockedCounter()
        let watcher = DirectoryWatcher(roots: [scratch], debounce: 0.05) {
            fires.bump()
        }
        watcher.canOpenTarget = { url in
            guard url.path == failing.path else { return true }
            attempts.bump()
            return false
        }
        watcher.start()
        XCTAssertTrue(waitFor { watcher.failedCount == 1 },
                      "failing open never recorded")
        XCTAssertEqual(attempts.value, 1)

        // Events on the healthy subtree keep arriving — the failed open
        // neither tears it down nor retries inside the cooldown.
        for i in 0..<3 {
            let before = fires.value
            try "x".write(to: healthy.appendingPathComponent("e\(i).txt"),
                          atomically: true, encoding: .utf8)
            XCTAssertTrue(waitFor { fires.value > before },
                          "event on the healthy subtree did not fire")
        }
        XCTAssertEqual(attempts.value, 1,
                       "failed open retried inside the cooldown")
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

    /// A lock-guarded flag the `canOpenTarget` seam reads on the
    /// watcher's queue — no sleeps, just a happens-after edge.
    private final class OpenGate {
        private let lock = NSLock()
        private var open = false
        var isAllowed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return open
        }
        func allow() {
            lock.lock()
            open = true
            lock.unlock()
        }
    }

    /// Lock-guarded counter for events and open attempts observed off
    /// the test thread.
    private final class LockedCounter {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        func bump() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }
}
