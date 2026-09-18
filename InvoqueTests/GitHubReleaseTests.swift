import XCTest
@testable import Invoque

final class GitHubReleaseTests: XCTestCase {

    /// A default-configured decoder on purpose — GitHubRelease parses
    /// `published_at` itself, so correctness can't depend on decoder
    /// configuration at the call site.
    private func decode(_ json: String) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    func testDecodesLatestReleasePayload() throws {
        let release = try decode("""
        {
          "tag_name": "v1.3.0",
          "name": "Invoque 1.3.0",
          "body": "- Fixed a thing\\n- Added another",
          "html_url": "https://github.com/L-K-M/Invoque/releases/tag/v1.3.0",
          "prerelease": false,
          "draft": false,
          "published_at": "2026-05-01T12:00:00Z",
          "assets": [
            {
              "name": "Invoque.dmg",
              "content_type": "application/x-apple-diskimage",
              "size": 1048576,
              "browser_download_url": "https://github.com/L-K-M/Invoque/releases/download/v1.3.0/Invoque.dmg"
            }
          ]
        }
        """)

        XCTAssertEqual(release.tagName, "v1.3.0")
        XCTAssertEqual(SemanticVersion(release.tagName), SemanticVersion("1.3.0"))
        XCTAssertFalse(release.prerelease)
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/L-K-M/Invoque/releases/tag/v1.3.0")
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets.first?.name, "Invoque.dmg")
        XCTAssertEqual(release.assets.first?.browserDownloadURL.lastPathComponent, "Invoque.dmg")
        XCTAssertNotNil(release.publishedAt)
    }

    func testDecodesWithMissingOptionalFields() throws {
        // body/name/published_at absent, no assets — must still decode.
        let release = try decode("""
        {
          "tag_name": "2.0",
          "html_url": "https://github.com/L-K-M/Invoque/releases/tag/2.0",
          "prerelease": true,
          "draft": false,
          "assets": []
        }
        """)
        XCTAssertEqual(release.tagName, "2.0")
        XCTAssertTrue(release.prerelease)
        XCTAssertNil(release.releaseNotes())
        XCTAssertTrue(release.assets.isEmpty)
    }

    func testPreferredAssetPrefersDiskImageThenZip() throws {
        let release = try decode("""
        {
          "tag_name": "1.0", "html_url": "https://e.com", "prerelease": false, "draft": false,
          "assets": [
            {"name":"App.zip","content_type":"application/zip","size":1,"browser_download_url":"https://e.com/App.zip"},
            {"name":"App.dmg","content_type":"application/x-apple-diskimage","size":1,"browser_download_url":"https://e.com/App.dmg"}
          ]
        }
        """)
        XCTAssertEqual(release.preferredAsset?.name, "App.dmg")
    }

    func testPreferredAssetFallsBackToFirstWhenNoKnownType() throws {
        let release = try decode("""
        {
          "tag_name": "1.0", "html_url": "https://e.com", "prerelease": false, "draft": false,
          "assets": [
            {"name":"notes.txt","content_type":"text/plain","size":1,"browser_download_url":"https://e.com/notes.txt"}
          ]
        }
        """)
        XCTAssertEqual(release.preferredAsset?.name, "notes.txt")
    }

    /// Multi-arch releases are a common GitHub layout — among same-extension
    /// assets the one hinting at the running architecture must win.
    func testPreferredAssetPrefersMatchingArchitecture() throws {
        let release = try decode("""
        {
          "tag_name": "1.0", "html_url": "https://e.com", "prerelease": false, "draft": false,
          "assets": [
            {"name":"App-x64.dmg","content_type":"application/x-apple-diskimage","size":1,"browser_download_url":"https://e.com/x64.dmg"},
            {"name":"App-arm64.dmg","content_type":"application/x-apple-diskimage","size":1,"browser_download_url":"https://e.com/arm64.dmg"}
          ]
        }
        """)
        #if arch(arm64)
        XCTAssertEqual(release.preferredAsset?.name, "App-arm64.dmg")
        #else
        XCTAssertEqual(release.preferredAsset?.name, "App-x64.dmg")
        #endif
    }

    /// An un-suffixed asset — often the universal/default build — must beat
    /// one explicitly tagged for the other architecture, regardless of order.
    func testPreferredAssetUnhintedBeatsForeignArch() throws {
        let release = try decode("""
        {
          "tag_name": "1.0", "html_url": "https://e.com", "prerelease": false, "draft": false,
          "assets": [
            {"name":"App-x64.dmg","content_type":"application/x-apple-diskimage","size":1,"browser_download_url":"https://e.com/x64.dmg"},
            {"name":"App.dmg","content_type":"application/x-apple-diskimage","size":1,"browser_download_url":"https://e.com/app.dmg"}
          ]
        }
        """)
        #if arch(arm64)
        // "App.dmg" (unhinted) beats the explicitly foreign x64 build.
        XCTAssertEqual(release.preferredAsset?.name, "App.dmg")
        #else
        // On Intel the x64 build is native — it still wins.
        XCTAssertEqual(release.preferredAsset?.name, "App-x64.dmg")
        #endif
    }

    /// Extension preference still dominates the architecture tie-break — a
    /// foreign-arch dmg beats a native-arch zip on every architecture.
    func testPreferredAssetExtensionDominatesArch() throws {
        let release = try decode("""
        {
          "tag_name": "1.0", "html_url": "https://e.com", "prerelease": false, "draft": false,
          "assets": [
            {"name":"App-arm64.zip","content_type":"application/zip","size":1,"browser_download_url":"https://e.com/arm64.zip"},
            {"name":"App-x64.dmg","content_type":"application/x-apple-diskimage","size":1,"browser_download_url":"https://e.com/x64.dmg"}
          ]
        }
        """)
        // On arm64 the x64 dmg is foreign-arch but still wins — ext first.
        // On x86_64 it wins on both criteria.
        XCTAssertEqual(release.preferredAsset?.name, "App-x64.dmg")
    }

    func testPreferredAssetNilWhenNoAssets() throws {
        let release = try decode("""
        { "tag_name": "1.0", "html_url": "https://e.com", "prerelease": false, "draft": false, "assets": [] }
        """)
        XCTAssertNil(release.preferredAsset)
    }

    func testReleaseNotesAreTrimmedAndCapped() throws {
        let long = String(repeating: "x", count: 1000)
        let release = try decode("""
        { "tag_name": "1.0", "html_url": "https://example.com", "prerelease": false, "draft": false, "assets": [], "body": "  \(long)  " }
        """)
        let notes = release.releaseNotes(maxLength: 100)
        XCTAssertEqual(notes?.count, 101)             // 100 chars + the ellipsis
        XCTAssertEqual(notes?.last, "…")
    }
}
