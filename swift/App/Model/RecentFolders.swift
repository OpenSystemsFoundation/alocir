import Foundation

/// Recently scanned folders, kept as security-scoped bookmarks so the
/// sandboxed app can open them again after a relaunch. At most ten.
@MainActor
@Observable
final class RecentFolders {
    struct Entry: Codable, Identifiable, Equatable {
        var bookmark: Data
        var path: String
        var lastSize: UInt64?
        var lastScan: Date?
        var id: String { path }
        var name: String {
            path == "/" ? String(localized: "Startup Disk") : (path as NSString).lastPathComponent
        }
    }

    static let shared = RecentFolders()
    static let limit = 10

    private(set) var entries: [Entry] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "recentFolders"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        {
            entries = decoded
        }
    }

    /// Records a scan of `url` (already being accessed), newest first.
    func record(_ url: URL, size: UInt64? = nil) {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let existing = entries.first { $0.path == path }
        let bookmark = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? existing?.bookmark
        guard let bookmark else { return }
        entries.removeAll { $0.path == path }
        entries.insert(Entry(bookmark: bookmark, path: path, lastSize: size ?? existing?.lastSize, lastScan: size == nil ? existing?.lastScan : .now), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    /// Resolves an entry to a URL, refreshing a stale bookmark. The caller
    /// must call `startAccessingSecurityScopedResource` on it.
    func resolve(_ entry: Entry) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: entry.bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
                let index = entries.firstIndex(of: entry)
            {
                entries[index].bookmark = fresh
                save()
            }
        }
        return url
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0 == entry }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// For screenshots: entries that are shown but never opened.
    func replaceForDemo(_ demo: [Entry]) {
        entries = demo
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}
