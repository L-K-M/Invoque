import XCTest
@testable import Invoque

/// Covers `fetchOutcome`, the testable half of `invoque.fetch`: the
/// URLSession download plumbing around it is the untestable shell.
final class InvoqueBridgeTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
        try super.tearDownWithError()
    }

    private func httpResponse(_ code: Int = 200) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com/x")!,
                        statusCode: code, httpVersion: nil,
                        headerFields: nil)!
    }

    private func writeBody(_ bytes: Int, named name: String = "body.bin") throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }

    /// A transport error rejects with the underlying description.
    func testFetchOutcomePropagatesError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        guard case .failure(let message) = InvoqueBridge.fetchOutcome(
            fileURL: nil, response: nil, error: error) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(message.hasPrefix("invoque.fetch:"))
        XCTAssertTrue(message.contains(error.localizedDescription),
                      "the underlying transport error should reach the caller")
    }

    /// A response whose final URL left http(s) is refused — the redirect
    /// guard's defense-in-depth twin.
    func testFetchOutcomeRejectsNonHTTPFinalURL() throws {
        let file = try writeBody(4)
        let response = URLResponse(url: URL(fileURLWithPath: "/tmp/x"),
                                   mimeType: nil, expectedContentLength: 0,
                                   textEncodingName: nil)
        guard case .failure(let message) = InvoqueBridge.fetchOutcome(
            fileURL: file, response: response, error: nil) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(message.contains("redirect left http(s)"))
    }

    /// A body over the cap is rejected, not buffered — the memory-
    /// exhaustion fix this type exists for.
    func testFetchOutcomeRejectsOverCapBody() throws {
        let file = try writeBody(InvoqueBridge.maxFetchBytes + 1)
        guard case .failure(let message) = InvoqueBridge.fetchOutcome(
            fileURL: file, response: httpResponse(), error: nil) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(message.contains("\(InvoqueBridge.maxFetchBytes / 1024 / 1024) MB"))
    }

    /// A body at the cap still resolves — the limit is a bound, not a
    /// fence one byte early.
    func testFetchOutcomeAllowsBodyAtCap() throws {
        let file = try writeBody(InvoqueBridge.maxFetchBytes)
        guard case .success(let status, _) = InvoqueBridge.fetchOutcome(
            fileURL: file, response: httpResponse(), error: nil) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(status, 200)
    }

    /// A normal response resolves with its status and decoded body.
    func testFetchOutcomeReturnsStatusAndBody() throws {
        let file = scratch.appendingPathComponent("body.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        guard case .success(let status, let body) = InvoqueBridge.fetchOutcome(
            fileURL: file, response: httpResponse(201), error: nil) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(status, 201)
        XCTAssertEqual(body, "hello")
    }

    /// No downloaded file means no body to read — a distinct failure from
    /// an over-cap one.
    func testFetchOutcomeFailsWithoutFile() {
        guard case .failure(let message) = InvoqueBridge.fetchOutcome(
            fileURL: nil, response: httpResponse(), error: nil) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(message.contains("no readable body"))
    }

    /// A body that exists on disk but isn't a readable regular file
    /// fails distinctly — not as a silent empty string. A directory URL
    /// is the fixture: it fails the `isRegularFile` check — robust to
    /// CI running as root, where permission bits can't force the failure.
    func testFetchOutcomeFailsOnUnreadableBody() throws {
        let dir = scratch.appendingPathComponent("unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: false)
        guard case .failure(let message) = InvoqueBridge.fetchOutcome(
            fileURL: dir, response: httpResponse(), error: nil) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(message.contains("could not read body"))
    }
}
