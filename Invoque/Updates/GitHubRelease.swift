import Foundation

/// The subset of GitHub's Releases API we care about.
/// See <https://docs.github.com/en/rest/releases/releases>.
///
/// Reusable across apps — depends only on Foundation.
struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let prerelease: Bool
    let draft: Bool
    let publishedAt: Date?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let contentType: String
        let size: Int
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case contentType = "content_type"
            case size
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body
        case htmlURL = "html_url"
        case prerelease, draft
        case publishedAt = "published_at"
        case assets
    }

    /// The best asset to download: a disk image, then a zip, then a pkg, else the
    /// first uploaded asset. `nil` if the release has no assets. (GitHub's
    /// auto-generated "Source code" archives aren't in `assets`, so they're never
    /// picked.) Among same-extension assets, prefer one whose name hints at the
    /// running architecture — multi-arch releases are a common GitHub layout.
    var preferredAsset: Asset? {
        let preference = ["dmg", "zip", "pkg"]
        #if arch(arm64)
        let archHints = ["arm64", "aarch64", "universal"]
        #else
        let archHints = ["x86_64", "x64", "intel", "universal"]
        #endif
        func rank(_ asset: Asset) -> Int {
            let ext = (asset.name as NSString).pathExtension.lowercased()
            let extRank = preference.firstIndex(of: ext) ?? preference.count
            let name = asset.name.lowercased()
            let archRank = archHints.contains { name.contains($0) } ? 0 : 1
            return extRank * 2 + archRank   // extension dominates the tie-break
        }
        return assets.min { rank($0) < rank($1) }
    }

    /// A trimmed, length-capped form of the release body, suitable for an alert's
    /// informative text (markdown is shown as-is — GitHub bodies are mostly plain).
    func releaseNotes(maxLength: Int = 600) -> String? {
        guard let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
        guard body.count > maxLength else { return body }
        let end = body.index(body.startIndex, offsetBy: maxLength)
        return String(body[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
