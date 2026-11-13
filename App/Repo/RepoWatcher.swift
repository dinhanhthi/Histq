// Watches a repo's worktree and git dir with FSEvents and asks for a refresh of what changed: `status` for the
// worktree and the index, `refs` for HEAD, refs and packed-refs. Objects and lock files are ignored, and a burst of
// changes becomes one refresh 250 ms after the last one.
import CoreServices
import Foundation
import HistqCore

/// What a refresh reloads. `refs` also reloads the log when a ref moved (see `RepoSession.refresh(scope:)`).
struct RefreshScope: OptionSet, Sendable, CustomStringConvertible {
    let rawValue: Int

    static let status = RefreshScope(rawValue: 1 << 0)
    static let refs = RefreshScope(rawValue: 1 << 1)
    static let log = RefreshScope(rawValue: 1 << 2)

    /// `status`, `refs`, `log`, joined with `+` (`status+refs`): the `refresh` timing line's detail.
    var description: String {
        [(Self.status, "status"), (.refs, "refs"), (.log, "log")]
            .filter { contains($0.0) }
            .map(\.1)
            .joined(separator: "+")
    }
}

/// The folders a repo's watcher covers, from `git rev-parse` run with the read environment.
struct RepoDirectories: Sendable {
    /// The worktree's top folder.
    let worktree: URL
    /// The worktree's git dir (`.git`, or `<common>/worktrees/<name>` for a linked worktree): HEAD and the index.
    let gitDir: URL
    /// The repo's shared git dir: refs and packed-refs (the same as `gitDir` outside a linked worktree).
    let commonDir: URL

    /// Resolves the folders of the repo at `cwd`. `env` is the read environment for `cwd`. Throws `GitError` when
    /// `cwd` is not in a worktree (a plain folder, a bare repo).
    static func resolve(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> RepoDirectories {
        let result = try await runner.run(
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"],
            cwd: cwd, env: env, timeout: .seconds(10))
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, lines[0...2].allSatisfy({ $0.hasPrefix("/") }) else {
            throw GitError.other(exit: result.exitCode, stderrTail: "unexpected rev-parse output")
        }
        // FSEvents reports real paths (`/private/tmp`, not `/tmp`).
        let url = { (path: String) in URL(filePath: realPath(path), directoryHint: .isDirectory) }
        return RepoDirectories(worktree: url(lines[0]), gitDir: url(lines[1]), commonDir: url(lines[2]))
    }

    /// `path` with every symlink resolved, as FSEvents reports it (`realpath(3)`); `path` itself when that fails.
    /// Not `URL.resolvingSymlinksInPath()`: it strips `/private` (`/private/tmp/x` becomes `/tmp/x`).
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// FSEvents on a repo's worktree and git dirs. Events are classified and debounced on a private queue; `onChange`
/// runs on the main actor with the coalesced scope. Reads by Histq write nothing in these folders (they run with
/// `GIT_OPTIONAL_LOCKS=0` and no index refresh), so a refresh never triggers another one. Call `stop()` when the
/// repo closes; it is idempotent and also stops a `start` that has not happened yet.
final class RepoWatcher: @unchecked Sendable {
    // Every mutable property is only touched on `queue`.
    private let queue = DispatchQueue(label: "com.math2it.histq.watcher", qos: .utility)
    private var onChange: (@MainActor @Sendable (RefreshScope) -> Void)?
    private var stream: FSEventStreamRef?
    private var directories: RepoDirectories?
    private var pending: RefreshScope = []
    private var debounce: DispatchWorkItem?
    private var stopped = false

    /// The quiet time after the last change before the refresh runs.
    static let debounceInterval: DispatchTimeInterval = .milliseconds(250)

    /// Starts watching `directories` (once; later calls are ignored). `onChange` gets each coalesced scope.
    func start(_ directories: RepoDirectories, onChange: @escaping @MainActor @Sendable (RefreshScope) -> Void) {
        queue.async { [self] in
            guard !stopped, stream == nil else { return }
            self.directories = directories
            self.onChange = onChange
            // One stream for every root not already inside another (the git dir usually is in the worktree).
            let candidates = [directories.worktree, directories.gitDir, directories.commonDir].map(\.path)
            var roots: [String] = []
            for path in candidates where !roots.contains(where: { Self.isInside(path, $0) }) {
                roots.removeAll { Self.isInside($0, path) }
                roots.append(path)
            }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                copyDescription: nil)
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
            guard let stream = FSEventStreamCreate(
                nil, Self.callback, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.05, flags)
            else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            self.stream = stream
        }
    }

    /// Stops the stream and drops a pending refresh. The work runs on the watcher's queue, which keeps the watcher
    /// alive until the stream is invalidated, so no callback runs after it.
    func stop() {
        queue.async { [self] in
            stopped = true
            onChange = nil
            debounce?.cancel()
            debounce = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        let flags = Array(UnsafeBufferPointer(start: flags, count: count))
        watcher.received(paths: paths, flags: flags)
    }

    /// On `queue`: adds the scope of each path and restarts the debounce.
    private func received(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard !stopped, let directories else { return }
        var scope: RefreshScope = []
        for (index, path) in paths.enumerated() {
            let flag = index < flags.count ? Int(flags[index]) : 0
            // The kernel dropped events or a root moved: reload everything.
            if flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 {
                scope.formUnion([.status, .refs])
            } else {
                scope.formUnion(Self.scope(of: path, in: directories))
            }
        }
        guard !scope.isEmpty else { return }
        pending.formUnion(scope)
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fire() }
        debounce = work
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    /// On `queue`: hands the coalesced scope to the main actor.
    private func fire() {
        guard !stopped, !pending.isEmpty, let onChange else { return }
        let scope = pending
        pending = []
        debounce = nil
        Task { @MainActor in
            UITiming.refresh(scope.description)
            onChange(scope)
        }
    }

    /// Histq's own files (the timing and refresh logs of a DEBUG state dir, Application Support): a repo that
    /// contains them (a QA run on the Histq checkout, a dotfiles repo in the home folder) must not refresh on them,
    /// or each `refresh` line would trigger the next refresh.
    private static let ownFiles = RepoDirectories.realPath(StatePaths.root.path)

    /// The refresh a change at `path` needs: git-dir paths first (only HEAD, refs, packed-refs and the index count;
    /// objects, logs, worktrees and the rest are ignored), then any other worktree path is `status`. Git's lock files
    /// (`*.lock` in a git dir) never count: git renames a lock over the real file, which is the event that matters. A
    /// worktree file such as `Cargo.lock` does. Histq's own files never count.
    static func scope(of path: String, in directories: RepoDirectories) -> RefreshScope {
        if isInside(path, ownFiles) { return [] }
        for dir in [directories.gitDir.path, directories.commonDir.path] {
            guard let relative = relativePath(path, in: dir) else { continue }
            if relative.hasSuffix(".lock") { return [] }
            switch relative {
            case "HEAD", "packed-refs": return .refs
            case "index": return .status
            // A merge, cherry-pick or revert started or ended: the status shows the conflicts.
            case "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD": return .status
            default: return relative.hasPrefix("refs/") ? .refs : []
            }
        }
        return isInside(path, directories.worktree.path) ? .status : []
    }

    /// `path` relative to `root` ("" for the root itself), or nil when it is outside.
    private static func relativePath(_ path: String, in root: String) -> String? {
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// Whether `path` is `root` or inside it.
    private static func isInside(_ path: String, _ root: String) -> Bool {
        relativePath(path, in: root) != nil
    }
}
