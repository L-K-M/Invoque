import XCTest
@testable import Invoque

final class UpdateCheckerTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "UpdateCheckerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    /// Returns a release whose `tag_name` is `tag`; the payload shape matches
    /// what `GitHubReleaseClient` decodes. Encoded via JSONSerialization so a
    /// tag needing escaping can't corrupt the fixture.
    private func release(tag: String) throws -> GitHubRelease {
        let payload: [String: Any] = ["tag_name": tag,
                                      "html_url": "https://example.com/r",
                                      "prerelease": false, "draft": false,
                                      "assets": []]
        return try JSONDecoder().decode(
            GitHubRelease.self,
            from: try JSONSerialization.data(withJSONObject: payload))
    }

    private final class StubReleaseClient: UpdateChecker.ReleaseFetching, @unchecked Sendable {
        var release: GitHubRelease
        private let lock = NSLock()
        private var storage = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return storage }
        init(release: GitHubRelease) { self.release = release }
        func latestRelease(includePrereleases: Bool) async throws -> GitHubRelease {
            lock.withLock { storage += 1 }
            return release
        }
    }

    private func makeChecker(client: any UpdateChecker.ReleaseFetching) -> UpdateChecker {
        UpdateChecker(
            configuration: .init(owner: "test", repo: "test",
                                 appName: "Test", currentVersion: "1.0"),
            defaults: defaults, client: client)
    }

    /// Polls until `condition` holds or ~1 s elapses — `performCheck` hops to
    /// the MainActor, so assertions can't run synchronously after the call.
    private func waitFor(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Records every `onPendingUpdateChanged` emission so tests can tell
    /// "never fired" apart from "fired with nil".
    private final class PendingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String?] = []
        var calls: [String?] { lock.lock(); defer { lock.unlock() }; return storage }
        var handler: (String?) -> Void { { [weak self] tag in self?.record(tag) } }
        private func record(_ tag: String?) {
            lock.lock(); defer { lock.unlock() }
            storage.append(tag)
        }
    }

    /// A newer release found in the background while Invoque is inactive must
    /// queue — the status-menu surface fires — never a focus-stealing modal.
    func testBackgroundCheckQueuesUpdateWhileInactive() async throws {
        let client = StubReleaseClient(release: try release(tag: "v9.9.9"))
        let checker = makeChecker(client: client)
        let probe = PendingProbe()
        checker.onPendingUpdateChanged = probe.handler

        checker.checkInBackground()
        let queued = await waitFor { !probe.calls.isEmpty }
        XCTAssertTrue(queued, "background check should surface a pending update")
        XCTAssertEqual(probe.calls.first, "v9.9.9")
        XCTAssertEqual(client.calls, 1)
    }

    /// A version the user skipped must not queue — and the skip must match
    /// semantically, so a retag ("v9.9.9" → "9.9.9") still counts as skipped.
    func testSkippedVersionDoesNotQueue() async throws {
        defaults.set("v9.9.9",
                     forKey: "UpdateChecker.test.test.skippedVersion")
        let client = StubReleaseClient(release: try release(tag: "9.9.9"))
        let checker = makeChecker(client: client)
        let probe = PendingProbe()
        checker.onPendingUpdateChanged = probe.handler

        checker.checkInBackground()
        // Wait for the fetch before treating isChecking as a completion
        // signal — the negative assertion must not race the check itself.
        let reached = await waitFor { client.calls == 1 }
        XCTAssertTrue(reached, "the check should reach the client")
        let done = await waitFor { !checker.isChecking }
        XCTAssertTrue(done)
        XCTAssertTrue(probe.calls.isEmpty,
                      "a semantically-equal skipped tag must not re-prompt")
    }

    /// A genuinely newer tag than the skipped one still queues.
    func testNewerThanSkippedStillQueues() async throws {
        defaults.set("v9.9.9",
                     forKey: "UpdateChecker.test.test.skippedVersion")
        let client = StubReleaseClient(release: try release(tag: "9.9.10"))
        let checker = makeChecker(client: client)
        let probe = PendingProbe()
        checker.onPendingUpdateChanged = probe.handler

        checker.checkInBackground()
        let queued = await waitFor { !probe.calls.isEmpty }
        XCTAssertTrue(queued)
        XCTAssertEqual(probe.calls.first, "9.9.10")
    }

    /// A second background check inside the throttle window must not hit the
    /// network again.
    func testBackgroundCheckIsThrottled() async throws {
        let client = StubReleaseClient(release: try release(tag: "1.0"))
        let checker = makeChecker(client: client)

        checker.checkInBackground()
        let first = await waitFor { client.calls == 1 && !checker.isChecking }
        XCTAssertTrue(first, "first background check should reach the client")

        checker.checkInBackground()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.calls, 1,
                       "the throttle window must suppress repeat checks")
    }

    /// A suspending stub: `latestRelease` parks on a continuation so a test
    /// can act while a check is in flight, then releases it.
    private final class SuspendedReleaseClient: UpdateChecker.ReleaseFetching, @unchecked Sendable {
        private let release: GitHubRelease
        private let lock = NSLock()
        private var continuation: CheckedContinuation<GitHubRelease, Never>?
        private var released = false
        private var storage = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return storage }
        init(release: GitHubRelease) { self.release = release }
        func latestRelease(includePrereleases: Bool) async throws -> GitHubRelease {
            lock.withLock { storage += 1 }
            return await withCheckedContinuation { c in
                let fastPath = lock.withLock { () -> GitHubRelease? in
                    if released { return release }
                    continuation = c
                    return nil
                }
                if let fastPath { c.resume(returning: fastPath) }
            }
        }
        /// Releases the suspended fetch — also valid if the fetch hasn't
        /// reached its suspension point yet (the Task hop is async).
        func resume() {
            lock.lock()
            released = true
            let c = continuation; continuation = nil
            lock.unlock()
            c?.resume(returning: release)
        }
    }

    /// Remote <= current reports nothing and queues nothing.
    func testOlderReleaseDoesNothing() async throws {
        let client = StubReleaseClient(release: try release(tag: "0.5"))
        let checker = makeChecker(client: client)
        let probe = PendingProbe()
        checker.onPendingUpdateChanged = probe.handler

        checker.checkInBackground()
        let reached = await waitFor { client.calls == 1 }
        XCTAssertTrue(reached, "the check should reach the client")
        let done = await waitFor { !checker.isChecking }
        XCTAssertTrue(done)
        XCTAssertTrue(probe.calls.isEmpty)
    }

    /// A checkNow() that arrives while a background fetch is in flight must be
    /// consumed by THAT run — not at task start (which drops the click and
    /// leaks the flag into the next automatic check). For a newer release,
    /// "reported" means presented rather than queued, so the pending-update
    /// callback must not fire.
    func testCheckNowDuringInFlightCheckIsConsumedByThatRun() async throws {
        let client = SuspendedReleaseClient(release: try release(tag: "9.9.9"))
        let checker = makeChecker(client: client)
        let probe = PendingProbe()
        checker.onPendingUpdateChanged = probe.handler

        checker.checkInBackground()        // fetch suspends mid-flight
        checker.checkNow()                 // marks this run user-requested
        client.resume()

        let done = await waitFor { !checker.isChecking }
        XCTAssertTrue(done)
        // The run must have fetched at all — the leak poll alone can't
        // distinguish "consumed" from "dropped".
        let fetchedOnce = await waitFor { client.calls >= 1 }
        XCTAssertTrue(fetchedOnce, "the user-initiated run must fetch")
        // The flag must be consumed-and-cleared at the read site: if it
        // leaked, the defer would queue a second user-initiated run.
        // Poll for that failure rather than sampling once after a fixed
        // delay — a loaded runner can schedule the queued task late.
        let leakedSecondFetch = await waitFor { client.calls > 1 }
        XCTAssertFalse(leakedSecondFetch,
                       "the user-request flag must be consumed at the read site")
        XCTAssertTrue(probe.calls.isEmpty,
                      "a run requested mid-flight must present, not queue")
    }
}
