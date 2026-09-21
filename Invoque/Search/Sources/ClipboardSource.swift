import AppKit
import Foundation

/// Captures recent clipboard entries and surfaces them as searchable results.
/// Typing "clip" or "paste" shows clipboard history; selecting an entry copies
/// it back to the clipboard. A polling timer checks for changes —
/// `NSPasteboard` has no change-notification API, so periodic comparison is
/// the standard approach (same as Alfred's clipboard history).
final class ClipboardSource: ItemSource {

    /// Maximum entries to retain. Oldest drop first.
    private let maxEntries = 50
    /// How often to poll the pasteboard for changes (seconds).
    private let pollInterval: TimeInterval = 0.5

    /// Stored entries, most recent last.
    private var entries: [Entry] = []
    /// The change count at the last poll — avoids re-storing identical content.
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    struct Entry: Identifiable {
        let id = UUID()
        let content: String
        let timestamp: Date
        /// Truncated preview for display — full content is the action payload.
        var preview: String {
            let oneLine = content.replacingOccurrences(of: "\n", with: " ")
            return String(oneLine.prefix(80))
        }
    }

    init() {
        // Snapshot whatever is on the clipboard right now.
        if let current = NSPasteboard.general.string(forType: .string),
           !current.isEmpty {
            entries = [Entry(content: current, timestamp: Date())]
            lastChangeCount = NSPasteboard.general.changeCount
        }
        startPolling()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: ItemSource

    func items(matching query: String) -> [Item] {
        // Only surface when the user explicitly asks for clipboard — typing
        // "clip" or "paste" routes here. Without a prefix match the source
        // returns nothing; `SearchModel` doesn't call unqualified queries
        // against every source.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("clip") || trimmed.hasPrefix("paste") else {
            return []
        }

        return entries.reversed().enumerated().map { index, entry in
            let ago = Self.relativeTime(entry.timestamp)
            return Item(
                id: "\(Item.clipboardIDPrefix)\(entry.id.uuidString)",
                title: entry.preview,
                subtitle: "Clipboard · \(ago)",
                icon: .symbol("doc.on.clipboard"),
                action: .copyText(entry.content),
                matchText: "\(entry.preview) clipboard paste clip history"
            )
        }
    }

    func reload() {
        pollClipboard()
    }

    // MARK: Polling

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollClipboard()
        }
    }

    private func pollClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard let content = pb.string(forType: .string), !content.isEmpty else { return }

        // Don't duplicate the most recent entry.
        if entries.last?.content == content { return }

        entries.append(Entry(content: content, timestamp: Date()))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    // MARK: Helpers

    private static func relativeTime(_ date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
