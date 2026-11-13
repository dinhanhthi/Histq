// The saved profiles, the default profile for new repos, and the last profile each repo was opened with. The
// app keeps them in one JSON file under its state folder (`StatePaths.root`, which lives in the app target, so
// the file URL is passed in). The store is a plain value: the app loads it once off the main thread, resolves
// new tabs from memory without waiting, and saves a copy in the background after each change.
//
// Repos are keyed by their real path (`realpath(3)`), the same form `RepoWatcher` uses, so `/tmp/x` and
// `/private/tmp/x`, or a symlinked folder and its target, remember one profile. A path that cannot be resolved
// (the folder is gone) is keyed by its standardized form, so it still finds what was saved under that spelling.
import Foundation

public struct ProfileStore: Codable, Sendable, Equatable {
    /// Every profile, in the order the user sees them.
    public private(set) var profiles: [Profile]
    /// The profile of repos that have none remembered. nil, or an id no profile has, means no profile: git then
    /// uses the user's own config.
    public var defaultProfileID: UUID?
    /// Real repo path to the id of the profile it was last used with.
    public private(set) var repoProfiles: [String: UUID]

    public init(profiles: [Profile] = [], defaultProfileID: UUID? = nil) {
        self.profiles = profiles
        self.defaultProfileID = defaultProfileID
        self.repoProfiles = [:]
    }

    // MARK: - File

    /// The store saved in `file`; an empty store when the file does not exist. A file that cannot be read or
    /// decoded throws instead of returning an empty store, so the next save never wipes the user's profiles.
    public static func load(from file: URL) throws -> ProfileStore {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return ProfileStore()
        }
        return try JSONDecoder().decode(ProfileStore.self, from: data)
    }

    /// Writes the store to `file` atomically (a temp file in the same folder, then `rename(2)`), so a crash or
    /// a concurrent load never sees half a file. The file is created with mode 600: it names the user's
    /// identities and key paths. The folder is created if missing.
    public func save(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appending(path: ".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path]) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temp.path, file.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
        } catch {
            unlink(temp.path)
            throw error
        }
    }

    // MARK: - Resolving

    /// The default profile, or nil when none is set or it no longer exists.
    public var defaultProfile: Profile? {
        defaultProfileID.flatMap(profile(id:))
    }

    public func profile(id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// The profile `repo` was last used with; the default profile when the repo has none remembered or its
    /// profile was deleted (an id read from disk may name a profile that is gone).
    public func profile(forRepo repo: URL) -> Profile? {
        repoProfiles[Self.repoKey(repo)].flatMap(profile(id:)) ?? defaultProfile
    }

    // MARK: - Changing

    /// Adds `profile`, or replaces the profile with the same id in place.
    public mutating func upsert(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// Removes the profile, the repos that remembered it (they fall back to the default) and, when it was the
    /// default, the default.
    public mutating func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        repoProfiles = repoProfiles.filter { $0.value != id }
        if defaultProfileID == id { defaultProfileID = nil }
    }

    /// Remembers `id` as `repo`'s profile, or forgets the repo's profile when `id` is nil.
    public mutating func remember(_ id: UUID?, forRepo repo: URL) {
        repoProfiles[Self.repoKey(repo)] = id
    }

    /// `repo`'s real path (`realpath(3)`, which keeps `/private` where `URL.resolvingSymlinksInPath()` strips
    /// it), or its standardized path when it cannot be resolved.
    public static func repoKey(_ repo: URL) -> String {
        let path = repo.standardizedFileURL.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else {
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
