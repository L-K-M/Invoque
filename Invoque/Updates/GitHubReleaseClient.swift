import Foundation

/// Fetches releases for a GitHub repository over the public REST API (no token —
/// unauthenticated requests are rate-limited to 60/hour per IP, ample for a
/// once-a-day check).
///
/// Reusable across apps — depends only on Foundation.
struct GitHubReleaseClient {
    let owner: String
    let repo: String
    var session: URLSession = .shared

    enum ClientError: LocalizedError {
        case badResponse(Int)
        case noReleases

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "GitHub returned HTTP \(code)."
            case .noReleases: return "No published releases were found (or the repository is unavailable)."
            }
        }
    }

    /// The newest published release. When `includePrereleases` is false this uses the
    /// repo's `releases/latest` endpoint (which already excludes drafts and
    /// pre-releases); otherwise it scans the recent releases and returns the
    /// highest-versioned non-draft one.
    func latestRelease(includePrereleases: Bool) async throws -> GitHubRelease {
        if includePrereleases {
            let releases = try await fetch([GitHubRelease].self, path: "releases?per_page=30")
            guard let newest = Self.newestParseableRelease(releases) else {
                throw ClientError.noReleases
            }
            return newest
        }
        return try await fetch(GitHubRelease.self, path: "releases/latest")
    }

    /// The highest-versioned non-draft release whose tag parses. Unparsable
    /// tags ("nightly", "build-42") are excluded rather than ranked as 0.0.0 —
    /// an all-unparsable page returns nil so the caller throws `noReleases`
    /// instead of surfacing an arbitrary release.
    static func newestParseableRelease(_ releases: [GitHubRelease]) -> GitHubRelease? {
        releases
            .filter { !$0.draft }
            .compactMap { release -> (GitHubRelease, SemanticVersion)? in
                SemanticVersion(release.tagName).map { (release, $0) }
            }
            .max { $0.1 < $1.1 }?.0
    }

    private func fetch<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        // A malformed owner/repo must throw, not crash — this type is
        // documented reusable and callers aren't guaranteed URL-safe.
        // Percent-encode each component to GitHub's naming alphabet so a
        // "?", "#" or "/" can't redirect the request to another path.
        var nameAllowed = CharacterSet.alphanumerics
        nameAllowed.insert(charactersIn: "-._")
        guard let encodedOwner = owner.addingPercentEncoding(withAllowedCharacters: nameAllowed),
              let encodedRepo = repo.addingPercentEncoding(withAllowedCharacters: nameAllowed),
              let url = URL(string: "https://api.github.com/repos/\(encodedOwner)/\(encodedRepo)/\(path)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub requires a User-Agent header; use the app's bundle id.
        request.setValue(Bundle.main.bundleIdentifier ?? "UpdateChecker", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse(-1) }
        // A 404 on the latest endpoint means "no published release yet" — or
        // a missing/private repo, which GitHub reports identically. The list
        // endpoint answers 200 [] for "none yet", so its 404 is unambiguously
        // repo-level: report it as such.
        if http.statusCode == 404 {
            if path.hasSuffix("releases/latest") { throw ClientError.noReleases }
            throw ClientError.badResponse(404)
        }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.badResponse(http.statusCode) }

        // GitHubRelease decodes published_at itself, so no date strategy
        // is needed here — the model can't be broken by decoder config.
        return try JSONDecoder().decode(T.self, from: data)
    }
}
