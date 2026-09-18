import Foundation

/// Downloads a release asset into the user's Downloads folder, picking a
/// non-colliding filename. Reusable across apps — depends only on Foundation.
struct UpdateDownloader {
    var session: URLSession = .shared
    var fileManager: FileManager = .default

    /// Downloads `asset` to `~/Downloads`, returning the saved file URL.
    func downloadToDownloads(_ asset: GitHubRelease.Asset) async throws -> URL {
        let (tempURL, response) = try await session.download(from: asset.browserDownloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // A completed-but-failed download leaves a full-size temp file —
            // reclaim it rather than leaking it until the next tmp purge.
            try? fileManager.removeItem(at: tempURL)
            throw GitHubReleaseClient.ClientError.badResponse(http.statusCode)
        }
        let downloads = try fileManager.url(for: .downloadsDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: true)
        let destination = Self.uniqueDestination(
            in: downloads, fileName: safeFileName(asset.name), fileManager: fileManager)
        try fileManager.moveItem(at: tempURL, to: destination)
        return destination
    }

    /// Reduces a remote-controlled asset name to a single path component —
    /// a crafted name ("../../x", "sub/dir/x") must not escape Downloads.
    /// "." and ".." pass `lastPathComponent` unchanged, so they're filtered
    /// too — ".." appended to Downloads would resolve to its parent.
    static func safeFileName(_ assetName: String) -> String {
        let raw = (assetName as NSString).lastPathComponent
        return raw.isEmpty || raw == "." || raw == ".." ? "download" : raw
    }

    /// A non-colliding URL in `directory` for `fileName` (`Foo.dmg`, then `Foo-1.dmg`,
    /// `Foo-2.dmg`, …) so re-downloading never clobbers an existing file.
    static func uniqueDestination(in directory: URL, fileName: String,
                                  fileManager: FileManager = .default) -> URL {
        let name = fileName.isEmpty ? "download" : fileName
        let first = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: first.path) else { return first }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 1
        while true {
            let candidateName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
