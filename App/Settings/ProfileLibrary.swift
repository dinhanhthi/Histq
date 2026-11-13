// The app's profiles: the `ProfileStore` in `StatePaths.root/profiles.json`, read once off the main thread and saved
// off it after each change, plus the file helpers the Profiles and SSH pages share (key paths, the global git
// identity, key files on disk).
import AppKit
import HistqCore
import os
import SwiftUI

/// The profiles every window shares. Settings edits them; each change is saved at once, in the background.
@Observable
@MainActor
final class ProfileLibrary {
    static let shared = ProfileLibrary()

    /// `.loading` until the file is read. `.failed` when the file exists but cannot be read or decoded: nothing is
    /// saved then, so the user's profiles are never replaced by an empty store.
    private(set) var state: Loadable<ProfileStore> = .idle
    /// The last failed save, shown on the Profiles page; nil once a save works again.
    private(set) var saveError: String?

    nonisolated static let file = StatePaths.root.appending(path: "profiles.json", directoryHint: .notDirectory)

    /// Numbers the changes, so the writer never replaces a newer save with an older one.
    @ObservationIgnored private var version = 0
    @ObservationIgnored private let writer = Writer()
    /// The read in flight or done, so `loaded()` can wait for it.
    @ObservationIgnored private var readTask: Task<Void, Never>?
    nonisolated private static let logger = Logger(subsystem: "com.math2it.histq", category: "profiles")

    private init() {}

    var store: ProfileStore? { state.value }

    /// Reads the file the first time a page needs it; later calls do nothing until `reload()`.
    func loadIfNeeded() {
        guard case .idle = state else { return }
        reload()
    }

    /// Reads the file again (the Try Again button of a failed read).
    func reload() {
        state = .loading
        readTask = Task { state = await Self.read() }
    }

    /// The store once the file is read (starting the read if nobody did); nil when it could not be read. A tab whose
    /// profile is not resolved yet waits here before a write, so it never commits as nobody by accident.
    func loaded() async -> ProfileStore? {
        loadIfNeeded()
        while case .loading = state, let readTask {
            await readTask.value
        }
        return store
    }

    @concurrent
    private nonisolated static func read() async -> Loadable<ProfileStore> {
        do {
            return .loaded(try ProfileStore.load(from: file))
        } catch {
            logger.error("profiles.json: \(error.localizedDescription, privacy: .public)")
            return .failed("Histq could not read its profiles file (\(file.path)), so it leaves it untouched. "
                + error.localizedDescription)
        }
    }

    /// Applies `change` to the loaded store and saves a copy off the main thread. Does nothing before the store is
    /// loaded or after a failed read.
    func update(_ change: (inout ProfileStore) -> Void) {
        guard let current = state.value else { return }
        var store = current
        change(&store)
        guard store != current else { return }
        state = .loaded(store)
        version += 1
        let version = version
        let writer = writer
        Task {
            switch await writer.write(store, version: version) {
            case .saved: saveError = nil
            case .failed(let message): saveError = message
            case .superseded: break
            }
        }
    }

    /// Writes snapshots one at a time, off the main thread, skipping any older than the last one written.
    private actor Writer {
        private var written = 0

        enum Outcome: Sendable {
            case saved
            case failed(String)
            /// A newer snapshot was written already.
            case superseded
        }

        func write(_ store: ProfileStore, version: Int) -> Outcome {
            guard version > written else { return .superseded }
            do {
                try store.save(to: ProfileLibrary.file)
                written = version
                return .saved
            } catch {
                ProfileLibrary.logger.error("saving profiles.json: \(error.localizedDescription, privacy: .public)")
                return .failed("Profiles could not be saved: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Profiles

    /// Adds a profile with the next free color and returns its id; `identity` fills its name and email.
    @discardableResult
    func addProfile(identity: Profile.Identity? = nil) -> UUID? {
        guard let store else { return nil }
        let used = Set(store.profiles.map(\.color))
        let color = ProfileColors.hexes.first { !used.contains($0) } ?? ProfileColors.hexes[0]
        let name = identity.map { $0.name.isEmpty ? $0.email : $0.name }.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Profile \(store.profiles.count + 1)"
        let profile = Profile(name: name, color: color,
                              identity: identity ?? Profile.Identity(name: "", email: ""))
        update { $0.upsert(profile) }
        return profile.id
    }

    /// Adds a copy of profile `id` ("<name> copy", new id, not the default) and returns its id.
    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard var copy = store?.profile(id: id) else { return nil }
        copy.id = UUID()
        copy.name += " copy"
        update { $0.upsert(copy) }
        return copy.id
    }

    func save(_ profile: Profile) {
        update { $0.upsert(profile) }
    }

    /// Changes profile `id` as it is in the store now (not a copy a view captured earlier, which two quick keystrokes
    /// could make stale), then saves.
    func modify(_ id: UUID, _ change: (inout Profile) -> Void) {
        update { store in
            guard var profile = store.profile(id: id) else { return }
            change(&profile)
            store.upsert(profile)
        }
    }

    func delete(_ id: UUID) {
        update { $0.delete(id: id) }
    }

    /// The profile of new tabs; nil for none (git then uses the user's own config).
    func setDefault(_ id: UUID?) {
        update { $0.defaultProfileID = id }
    }

    // MARK: Files

    /// `text` as an absolute path: trimmed, `~` expanded, standardized. nil for an empty or relative path: key paths
    /// are stored absolute, because ssh and git run with the repo as their folder.
    nonisolated static func absolutePath(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return (expanded as NSString).standardizingPath
    }

    /// `path` with the home folder shown as `~`, for display.
    nonisolated static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// The user's `user.name` and `user.email` from `git config --global` (empty when unset), read with the read
    /// environment from `/`, so no repo's config is involved.
    @concurrent
    nonisolated static func globalIdentity() async throws -> Profile.Identity {
        let toolchain = try await GitToolchain.resolve()
        let runner = GitRunner(executable: toolchain.executable.url)
        let env = GitInvocation.environment(profile: nil, base: toolchain.readBase, access: .read(filterDrivers: []))
        let root = URL(filePath: "/", directoryHint: .isDirectory)
        // Exit 1: the key is not set.
        let name = try await runner.run(["config", "--global", "--get", "user.name"], cwd: root, env: env,
                                        timeout: .seconds(10), allowedExitCodes: [0, 1])
        let email = try await runner.run(["config", "--global", "--get", "user.email"], cwd: root, env: env,
                                         timeout: .seconds(10), allowedExitCodes: [0, 1])
        return Profile.Identity(name: name.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                email: email.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What is on disk at a private key path and its `.pub`.
    struct KeyFiles: Equatable, Sendable {
        let privateExists: Bool
        /// The public key line, or nil when `<path>.pub` is missing or not a small text file.
        let publicKey: String?
    }

    @concurrent
    nonisolated static func keyFiles(at path: String) async -> KeyFiles {
        let manager = FileManager.default
        let privateExists = manager.fileExists(atPath: path)
        var publicKey: String?
        // A public key line is well under 16 KB; anything bigger is not one.
        if let handle = FileHandle(forReadingAtPath: path + ".pub") {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 16 * 1024), data.count < 16 * 1024,
               let text = String(data: data, encoding: .utf8) {
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                publicKey = line.isEmpty ? nil : line
            }
        }
        return KeyFiles(privateExists: privateExists, publicKey: publicKey)
    }

    /// Asks for a file with an open panel (hidden files shown, starting in `~/.ssh`) and returns its path.
    static func chooseFile(prompt: String, message: String, startingAt folder: String? = nil) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = prompt
        panel.message = message
        let start = folder ?? (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        panel.directoryURL = URL(filePath: start, directoryHint: .isDirectory)
        guard await panel.begin() == .OK else { return nil }
        return panel.url?.path(percentEncoded: false)
    }
}

/// The colors a profile can take: the graph's lane colors, stored as `#RRGGBB` in the profile.
enum ProfileColors {
    static let hexes: [String] = Palette.graphLanes.map(hex)

    /// The profile color `hex`, or the first lane color when it does not parse.
    static func color(_ hex: String) -> Color {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return Color(nsColor: Palette.graphLanes[0]) }
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    private static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func byte(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
