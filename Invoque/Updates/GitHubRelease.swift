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

    /// Self-contained decode: `published_at` arrives as an ISO 8601 string,
    /// which the default `.deferredToDate` strategy would reject — and the
    /// key being present means a thrown `typeMismatch`, not a nil. Parsing
    /// the string here keeps the type correct under any decoder configuration,
    /// which a "reusable" type can't outsource to its call sites.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        htmlURL = try c.decode(URL.self, forKey: .htmlURL)
        prerelease = try c.decode(Bool.self, forKey: .prerelease)
        draft = try c.decode(Bool.self, forKey: .draft)
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        assets = try c.decode([Asset].self, forKey: .assets)
    }

    /// The best asset to download: a disk image, then a zip, then a pkg, else the
    /// first uploaded asset. `nil` if the release has no assets. (GitHub's
    /// auto-generated "Source code" archives aren't in `assets`, so they're never
    /// picked.) Among same-extension assets, prefer one whose name hints at the
    /// running architecture — multi-arch releases are a common GitHub layout.
    var preferredAsset: Asset? {
        let preference = ["dmg", "zip", "pkg"]
        #if arch(arm64)
        let nativeHints = ["arm64", "aarch64", "universal"]
        let foreignHints = ["x86_64", "x64", "intel"]
        #else
        let nativeHints = ["x86_64", "x64", "intel", "universal"]
        let foreignHints = ["arm64", "aarch64"]
        #endif
        func rank(_ asset: Asset) -> Int {
            let ext = (asset.name as NSString).pathExtension.lowercased()
            let extRank = preference.firstIndex(of: ext) ?? preference.count
            let name = asset.name.lowercased()
            // Three tiers: explicit native match, no hint (often the universal
            // default), explicit foreign — an un-suffixed build beats one the
            // machine cannot run natively.
            let archRank: Int
            if nativeHints.contains(where: { name.contains($0) }) { archRank = 0 }
            else if foreignHints.contains(where: { name.contains($0) }) { archRank = 2 }
            else { archRank = 1 }
            return extRank * 3 + archRank   // extension dominates the tie-break
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
