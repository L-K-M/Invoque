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
    /// what `GitHubReleaseClient` decodes.
    private func release(tag: String) throws -> GitHubRelease {
        let json = """
        {
          "tag_name": "\(tag)",
          "html_url": "https://example.com/r",
          "prerelease": false, "draft": false, "assets": []
        }
        """
        return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    private final class StubReleaseClient: UpdateChecker.ReleaseFetching {
        var release: GitHubRelease
        var calls = 0
        init(release: GitHubRelease) { self.release = release }
        func latestRelease(includePrereleases: Bool) async throws -> GitHubRelease {
            calls += 1
            return release
        }
    }

    private func makeChecker(client: StubReleaseClient) -> UpdateChecker {
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
    private final class PendingProbe {
        var calls: [String?] = []
        var handler: (String?) -> Void { { [weak self] tag in self?.calls.append(tag) } }
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
        XCTAssertEqual(probe.calls.first!, "v9.9.9")
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
        XCTAssertEqual(probe.calls.first!, "9.9.10")
    }

    /// A second background check inside the throttle window must not hit the
    /// network again.
    func testBackgroundCheckIsThrottled() async throws {
        let client = StubReleaseClient(release: try release(tag: "1.0"))
        let checker = makeChecker(client: client)

        checker.checkInBackground()
        let first = await waitFor { client.calls == 1 }
        XCTAssertTrue(first, "first background check should reach the client")

        checker.checkInBackground()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.calls, 1,
                       "the throttle window must suppress repeat checks")
    }

    /// Remote <= current reports nothing and queues nothing.
    func testOlderReleaseDoesNothing() async throws {
        let client = StubReleaseClient(release: try release(tag: "0.5"))
        let checker = makeChecker(client: client)
        let probe = PendingProbe()
        checker.onPendingUpdateChanged = probe.handler

        checker.checkInBackground()
        let done = await waitFor { !checker.isChecking }
        XCTAssertTrue(done)
        XCTAssertTrue(probe.calls.isEmpty)
    }
}
