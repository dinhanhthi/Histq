// Session restore (Dblore `LaunchSession*`): the windows, their native tab groups and their app tabs, saved as JSON
// under `StatePaths.root` a second after each change and once more at quit, and read back off the main thread at the
// next launch that opens no folder. A repo folder that is gone (or no longer a git repository) comes back as a
// "Repo not found" tab.
import AppKit
import Foundation
import os

/// What the last run had open: one entry per document window, front group first.
struct SavedSession: Codable, Equatable, Sendable {
    /// The file format; a file of another version is ignored.
    static let currentVersion = 1

    var version = Self.currentVersion
    var windows: [SavedWindow]

    /// The windows by native tab group, groups front first, each group in its tab order.
    var groups: [[SavedWindow]] {
        Set(windows.map(\.group)).sorted().map { group in
            windows.filter { $0.group == group }.sorted { $0.tabIndex < $1.tabIndex }
        }
    }
}

/// A document window: its frame, its place in a native tab group, and its app tabs.
struct SavedWindow: Codable, Equatable, Sendable {
    /// Screen points, origin at the bottom left (`NSWindow.frame`).
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// Windows with the same group are native tabs of one window; groups are numbered front to back.
    var group: Int
    /// The window's place in its group's tab bar.
    var tabIndex: Int
    /// The native tab its group shows.
    var isSelectedInGroup: Bool
    var tabs: [SavedTab]
    /// The selected app tab's index.
    var selectedTab: Int?

    var frame: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

/// An app tab: a repo folder with its profile and its graph selection, or a Welcome tab.
struct SavedTab: Codable, Equatable, Sendable {
    /// The repo folder; nil for a Welcome tab.
    var path: String?
    /// The tab's profile as chosen in that session; nil when it was not known yet (the repo then resolves its own,
    /// as a new tab does).
    var profile: SavedProfile?
    /// The commit selected in the graph; nil reopens as a new tab does: the WIP when the working tree has changes,
    /// else HEAD. A selected WIP is saved as nil for that reason, and a stash or several rows are not kept.
    var commit: String?
}

/// A tab's profile choice. Stored as one string: a profile id, or "none" (git uses the user's own config).
enum SavedProfile: Codable, Equatable, Sendable {
    case none
    case id(UUID)

    var profileID: UUID? {
        if case .id(let id) = self { id } else { nil }
    }

    init(_ profileID: UUID?) {
        self = profileID.map(Self.id) ?? .none
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = UUID(uuidString: text).map(Self.id) ?? .none
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(profileID?.uuidString ?? "none")
    }
}

/// Reads the saved session at launch and writes it on changes. Capture is off until the launch has opened its
/// windows (restored or not), and stops for good once quit begins: the closing windows must not save an empty
/// session over the one quit wrote.
@MainActor
enum SessionStore {
    /// A saved session read at launch, with the repo folders that are gone or no longer git repositories.
    struct Loaded: Sendable {
        let session: SavedSession
        let missing: Set<String>
    }

    private static let debounce: Duration = .seconds(1)
    private static var loadTask: Task<Loaded?, Never>?
    /// Builds the current session; set by `start`, which turns capture on.
    private static var capture: (() -> SavedSession)?
    private static var pending: Task<Void, Never>?
    private static var isQuitting = false
    /// Writes in call order off the main thread; quit waits on it.
    private static let queue = DispatchQueue(label: "com.math2it.histq.session")
    private nonisolated static let logger = Logger(subsystem: "com.math2it.histq", category: "session")

    /// `session.json` in the state folder: Application Support, or the DEBUG `-HistqStateDir` of a QA run.
    static var file: URL { StatePaths.root.appending(path: "session.json", directoryHint: .notDirectory) }

    /// Starts reading the saved session off the main thread; called once at the top of `main()`, so the read is
    /// usually done before the launch asks for it.
    static func startLoading() {
        let file = file
        loadTask = Task.detached(priority: .userInitiated) { load(from: file) }
    }

    /// The saved session, once read; nil when there is none, it cannot be decoded, or it has no window.
    static func loaded() async -> Loaded? {
        await loadTask?.value
    }

    /// Turns capture on with `capture` as the source; the launch calls it once its windows are open.
    static func start(_ capture: @escaping () -> SavedSession) {
        self.capture = capture
    }

    /// Saves the session a second after the last change, so a crash or a kill still finds a recent one.
    static func schedule() {
        guard capture != nil, !isQuitting else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard !isQuitting, let capture else { return }
            let session = capture()
            let file = file
            queue.async { write(session, to: file) }
        }
    }

    /// Quit: stops the debounced writer and saves the session while the windows are still open, before the process
    /// exits (the write is waited for).
    static func saveForQuit() {
        guard !isQuitting else { return }
        isQuitting = true
        pending?.cancel()
        pending = nil
        guard let capture else { return }
        let session = capture()
        let file = file
        queue.sync { write(session, to: file) }
    }

    // MARK: File

    private nonisolated static func load(from file: URL) -> Loaded? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let session = try? JSONDecoder().decode(SavedSession.self, from: data),
              session.version == SavedSession.currentVersion
        else {
            logger.error("session.json ignored: unreadable or another version")
            return nil
        }
        // Closing the last window saves an empty session: a normal state, not a broken file.
        guard !session.windows.isEmpty else { return nil }
        let paths = Set(session.windows.flatMap { $0.tabs.compactMap(\.path) })
        return Loaded(session: session, missing: paths.filter { !isRepository($0) })
    }

    /// Whether `path` still opens as a repo: a folder inside a work tree (`.git` is a folder, or a file for a linked
    /// worktree or a submodule, in it or in a parent), or a bare repository. File checks only, no git.
    nonisolated static func isRepository(_ path: String) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let bare = ["HEAD", "objects", "refs"].allSatisfy { fm.fileExists(atPath: folder.appending(path: $0).path) }
        if bare { return true }
        var current = folder
        while true {
            if fm.fileExists(atPath: current.appending(path: ".git").path) { return true }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return false }
            current = parent
        }
    }

    /// Writes `session` atomically (a temp file in the same folder, then `rename(2)`), with mode 600: it lists the
    /// user's repo paths. As `ProfileStore.save`.
    private nonisolated static func write(_ session: SavedSession, to file: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(session)
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temp = folder.appending(path: ".\(file.lastPathComponent).\(UUID().uuidString).tmp")
            let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path]) }
            do {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try handle.write(contentsOf: data)
                try handle.close()
                guard rename(temp.path, file.path) == 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
                }
            } catch {
                unlink(temp.path)
                throw error
            }
        } catch {
            logger.error("session.json not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
