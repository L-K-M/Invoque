import XCTest
@testable import Invoque

final class GitHubReleaseClientTests: XCTestCase {

    private func release(tag: String, draft: Bool = false) throws -> GitHubRelease {
        let json = """
        {
          "tag_name": "\(tag)",
          "html_url": "https://example.com/r",
          "prerelease": false, "draft": \(draft), "assets": []
        }
        """
        return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    /// Mixed pages pick the highest *real* version — unparsable tags are
    /// excluded rather than silently ranked as 0.0.0.
    func testNewestParseableSkipsUnparsableTags() throws {
        let releases = [
            try release(tag: "nightly"),
            try release(tag: "v1.2.0"),
            try release(tag: "build-42"),
            try release(tag: "v1.10.0"),
        ]
        XCTAssertEqual(GitHubReleaseClient.newestParseableRelease(releases)?.tagName,
                       "v1.10.0")
    }

    /// An all-unparsable (or empty) page yields nil so the caller reports
    /// noReleases instead of surfacing an arbitrary release.
    func testNewestParseableAllUnparsableReturnsNil() throws {
        let releases = [try release(tag: "nightly"), try release(tag: "build-42")]
        XCTAssertNil(GitHubReleaseClient.newestParseableRelease(releases))
        XCTAssertNil(GitHubReleaseClient.newestParseableRelease([]))
    }

    /// Drafts never win even when their tag is the highest.
    func testNewestParseableExcludesDrafts() throws {
        let releases = [
            try release(tag: "v9.9.9", draft: true),
            try release(tag: "v1.0.0"),
        ]
        XCTAssertEqual(GitHubReleaseClient.newestParseableRelease(releases)?.tagName,
                       "v1.0.0")
    }
}
