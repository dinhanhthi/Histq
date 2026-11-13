// The repositories opened lately, most recent first, for the Welcome page. Kept in `Preferences.defaults`
// (`PrefKey.recentRepos`), so reading them never touches the disk on the main thread.
import Foundation
import Observation

@Observable
@MainActor
final class RecentRepos {
    static let shared = RecentRepos()
    /// How many folders the list keeps.
    static let limit = 10

    /// Folder URLs, most recent first.
    private(set) var urls: [URL]

    private static var key: String { PrefKey.recentRepos.rawValue }

    private init() {
        urls = (Preferences.defaults.stringArray(forKey: Self.key) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Puts `url` first (moving it up if already listed), keeping `limit` entries.
    func add(_ url: URL) {
        let url = url.standardizedFileURL
        var list = urls.filter { $0.path != url.path }
        list.insert(url, at: 0)
        urls = Array(list.prefix(Self.limit))
        save()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0.path == url.path }
        save()
    }

    private func save() {
        Preferences.defaults.set(urls.map(\.path), forKey: Self.key)
    }
}
