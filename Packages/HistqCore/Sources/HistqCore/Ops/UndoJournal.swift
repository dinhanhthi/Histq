// Undo and redo of local operations (task 9.1). Before and after each undoable operation `GitOperations` takes a
// snapshot of HEAD (its branch or detached commit), the local branches the operation touches, the index (as a tree
// from `write-tree`) and, for a discard, the content it throws away (`stash create` for tracked files, `hash-object
// -w` for untracked ones). Undo puts the before-snapshot back, redo the after-snapshot, both only while the
// repository still is in the other snapshot's state: a commit made in a terminal (or anything else the journal did
// not see) makes them refuse with `UndoError.repositoryChanged` instead of overwriting work.
//
// Storage: one JSON file per worktree, at a URL the caller gives (the app keys it like `ProfileStore.repoKey`
// under its state folder). Nothing is written inside `.git` except through git's own object and ref commands.
//
// Reachability (a decision, not an oversight): the journal adds no refs. A ref such as `refs/histq/undo/<id>` would
// keep its objects safe from `git gc`, but `push --mirror` pushes every ref (it would publish discarded content)
// and every other tool's `log --all` would show it. Instead the journal relies on git's defaults: objects it
// created (stash and index commits, trees, blobs) are fresh, and `gc` only prunes unreachable objects older than
// `gc.pruneExpire` (2 weeks); undone commits stay in the reflog. The expiry counts from an object's own mtime, not
// from when it became unreachable, so an old commit whose only ref was a deleted branch (and that is in no reflog)
// can go at the next `gc`. Undo and redo therefore check every object they need first (`cat-file --batch-check`)
// and refuse with `UndoError.objectsMissing` rather than restore half a state.
//
// Known limits: a deleted or renamed branch gets its ref and upstream (`branch.<name>.remote`/`.merge`) back, not
// its reflog or its other `branch.<name>.*` settings; a merge, rebase, cherry-pick or revert that stops on
// conflicts becomes undoable once it completes (the before-snapshot is kept as `pending` until then).
import Foundation

public enum UndoError: Error, Equatable, Sendable {
    /// `GitOperations` was made without a journal.
    case noJournal
    case nothingToUndo
    case nothingToRedo
    /// The repository is not in the state the journal left it in (HEAD, a branch, the index or the discarded files
    /// changed since), so undoing or redoing would overwrite work.
    case repositoryChanged
    /// A merge, rebase, cherry-pick or revert is in progress.
    case operationInProgress
    /// `git gc` pruned an object the snapshot needs.
    case objectsMissing
    /// A recorded untracked file path that would land outside the worktree.
    case unsafePath(String)
    /// The journal file holds something that is not a journal Histq wrote.
    case unreadableJournal

    /// A sentence for the UI.
    public var message: String {
        switch self {
        case .noJournal: "Undo is not available for this repository."
        case .nothingToUndo: "There is nothing to undo."
        case .nothingToRedo: "There is nothing to redo."
        case .repositoryChanged:
            "The repository changed since this operation (a commit, a staged file or a checkout Histq did not record, for example in a terminal), so it can no longer be undone or redone safely."
        case .operationInProgress: "Finish or abort the merge, rebase, cherry-pick or revert first."
        case .objectsMissing: "Git has cleaned up the objects this operation needs (git gc), so it can no longer be undone or redone."
        case .unsafePath(let path): "\"\(path)\" would be written outside the repository."
        case .unreadableJournal: "The undo history of this repository cannot be read."
        }
    }
}

public struct UndoJournal: Sendable {
    /// The operations the journal records.
    public enum Kind: String, Codable, Sendable {
        case commit, amend, checkout, reset, merge, rebase, cherryPick, revert
        case createBranch, deleteBranch, renameBranch, discard
    }

    /// Operations that change something the journal cannot take back, with the reason for the greyed Undo tooltip.
    public enum NotUndoable: Sendable, CaseIterable {
        case push, fetch, pull, deleteRemoteBranch, renameRemoteBranch, deleteRemoteTag, pushTag

        public var reason: String {
            switch self {
            case .push: "A push changed the remote; Histq cannot take it back."
            case .fetch: "A fetch only updates remote branches; there is nothing local to undo."
            case .pull: "A pull also fetched from the remote; Histq cannot take it back."
            case .deleteRemoteBranch: "Deleting a remote branch changed the remote; Histq cannot take it back."
            case .renameRemoteBranch: "Renaming a remote branch changed the remote; Histq cannot take it back."
            case .deleteRemoteTag: "Deleting a remote tag changed the remote; Histq cannot take it back."
            case .pushTag: "Pushing a tag changed the remote; Histq cannot take it back."
            }
        }
    }

    /// How an operation moved the index and the working tree, which says how to move them back.
    enum Mode: String, Codable, Sendable {
        /// Only the index (commit, amend, soft and mixed reset, branch operations): `read-tree <tree>`.
        case index
        /// Index and files together, carrying local changes (checkout, merge, rebase, cherry-pick, revert):
        /// `read-tree -m -u <current> <target>`, which refuses rather than overwrite a changed file.
        case carry
        /// Like `carry`, plus content the operation threw away (discard, hard reset), restored from `Content`.
        case discard
    }

    /// What a discard throws away: the tracked `paths` (literal pathspecs relative to `cwd`, `.` for its folder) and,
    /// when it removes untracked files, the untracked files under `untrackedPaths` (relative to `cwd` too, as `clean`
    /// reads them). `wholeWorktree`: the tracked part is the whole worktree whatever folder `cwd` is (`reset --hard`).
    struct ContentScope: Sendable {
        var paths: [String]
        var untrackedPaths: [String]?
        var wholeWorktree = false
    }

    struct Head: Codable, Equatable, Sendable {
        /// The full branch ref HEAD points at; nil when detached.
        var ref: String?
        /// HEAD's commit; nil on an unborn branch.
        var commit: String?
    }

    struct Upstream: Codable, Equatable, Sendable {
        var remote: String
        var merge: String
    }

    struct RefValue: Codable, Equatable, Sendable {
        /// A full local branch ref, `refs/heads/<name>`.
        var name: String
        /// nil when the branch does not exist.
        var oid: String?
        /// Only recorded for branches the operation creates, deletes or renames.
        var upstream: Upstream?
    }

    struct Snapshot: Codable, Equatable, Sendable {
        var head: Head
        var refs: [RefValue]
        /// The index as a tree (`write-tree`).
        var index: String

        /// Same HEAD, branch commits and index (upstreams are restored, never compared: setting one is not journaled).
        /// `ignoringIndex`: HEAD and branches only.
        func matches(_ other: Snapshot, ignoringIndex: Bool = false) -> Bool {
            head == other.head && (ignoringIndex || index == other.index)
                && refs.map { [$0.name, $0.oid ?? ""] } == other.refs.map { [$0.name, $0.oid ?? ""] }
        }

        func oid(of name: String) -> String? { refs.first { $0.name == name }?.oid }
    }

    struct UntrackedFile: Codable, Equatable, Sendable {
        enum FileKind: String, Codable, Sendable { case regular, executable, symlink }
        var path: String
        var blob: String
        var kind: FileKind
    }

    /// The before-state of the files a discard touched. Paths are relative to the worktree's top level, and every
    /// check, restore and redo of them runs from there (`topLevel`): a discard made from a subfolder comes back whole.
    struct Content: Codable, Equatable, Sendable {
        /// `stash create` of the tracked changes (its tree is the working tree); nil when there were none.
        var stash: String?
        var paths: [String]
        var untracked: [UntrackedFile]
        /// Whether the discard removed untracked files (redo removes the recorded ones again).
        var removesUntracked: Bool
    }

    public struct Entry: Codable, Identifiable, Sendable {
        public let id: UUID
        public let kind: Kind
        /// What the UI names it, e.g. `Commit "Fix login"` (shown as "Undo Commit "Fix login"").
        public let title: String
        public let date: Date
        let mode: Mode
        let before: Snapshot
        let after: Snapshot
        let content: Content?

        /// Undo and redo leave the index as it is (a commit, an amend, a soft reset, a branch create, delete or
        /// rename): files staged since then are no reason to refuse, so only HEAD and the branches are compared, and
        /// the staged changes stay staged (as `reset --soft` keeps them). A discard keeps the strict check: its
        /// content check compares the files with the index.
        var keepsIndex: Bool { before.index == after.index && mode != .discard }
    }

    /// An operation that stopped (conflicts, an `edit` stop) and becomes an entry once it completes.
    struct Pending: Codable, Sendable {
        var kind: Kind
        var title: String
        var mode: Mode
        var before: Snapshot
        /// `RepoState.Operation` in progress when it stopped, so another operation's completion never uses it.
        var operation: String
    }

    /// The journal file's content.
    public struct State: Codable, Sendable {
        var version = 1
        /// Oldest first; `undo.last` is undone next.
        public internal(set) var undo: [Entry] = []
        /// `redo.last` is redone next.
        public internal(set) var redo: [Entry] = []
        var pending: Pending?

        public var nextUndo: Entry? { undo.last }
        public var nextRedo: Entry? { redo.last }
    }

    /// The journal file (its folder is created on first write).
    public let file: URL
    /// The most entries kept for undo.
    public let limit: Int

    public init(file: URL, limit: Int = 50) {
        self.file = file
        self.limit = limit
    }

    /// The recorded history (empty when the file does not exist yet). Safe to call any time: writes are atomic.
    public func load() throws -> State {
        guard let data = try? Data(contentsOf: file) else { return State() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(State.self, from: data), state.version == 1 else {
            throw UndoError.unreadableJournal
        }
        return state
    }

    func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: file, options: .atomic)
    }

    // MARK: - Recording (inside the operation's write lane)

    /// The state an operation starts from.
    enum Start: Sendable {
        /// A new operation: its before-snapshot (with its discarded content).
        case fresh(names: [String], before: Snapshot, content: Content?)
        /// A merge, rebase, cherry-pick or revert (`RepoState.Operation`, described) was already in progress.
        /// `completes`: the operation is a commit, continue or skip, which may complete it.
        case continuing(operation: String, completes: Bool)
    }

    /// Takes the before-snapshot. nil when the operation cannot be journaled (the index has conflicts, the branch
    /// has no commit to stash against...): it still runs, and the next undo refuses because the state moved on.
    func begin(
        _ ops: GitOperations, refs: [String], content scope: ContentScope?, completesOperation: Bool
    ) async -> Start? {
        guard let state = try? await RepoState.read(runner: ops.runner, cwd: ops.cwd, env: ops.env) else { return nil }
        if state.isOperationInProgress {
            return .continuing(operation: String(describing: state.operation), completes: completesOperation)
        }
        do {
            var names = refs
            if let headRef = try await Self.headRef(ops), headRef.hasPrefix("refs/heads/"), !names.contains(headRef) {
                names.append(headRef)
            }
            let before = try await Self.capture(ops, names: names, upstreamOf: Set(refs))
            var content: Content?
            if let scope { content = try await Self.captureContent(ops, scope: scope) }
            return .fresh(names: names, before: before, content: content)
        } catch {
            return nil
        }
    }

    /// Records the operation once it ran (`succeeded` false when it threw). Never throws: the operation itself
    /// already happened, and a journal that cannot be written only means it cannot be undone.
    func finish(
        _ start: Start, kind: Kind, title: String, mode: Mode, refs: [String], succeeded: Bool, ops: GitOperations
    ) async {
        guard let operation = try? await RepoState.read(runner: ops.runner, cwd: ops.cwd, env: ops.env).operation else {
            return
        }
        var state = (try? load()) ?? State()
        switch start {
        case .fresh(let names, let before, let content):
            if operation != .none {
                // Stopped on conflicts or at an `edit`: keep the before-snapshot until it completes.
                state.pending = Pending(
                    kind: kind, title: title, mode: mode, before: before, operation: String(describing: operation))
            } else if succeeded, let after = try? await Self.capture(ops, names: names, upstreamOf: Set(refs)) {
                // An operation that changed nothing (a checkout of the current branch) is not worth an entry.
                let discarded = content.map { $0.stash != nil || !$0.untracked.isEmpty } ?? false
                guard !after.matches(before) || discarded else { return }
                append(Entry(
                    id: UUID(), kind: kind, title: title, date: Date(), mode: mode, before: before, after: after,
                    content: content), to: &state)
            } else {
                return
            }
        case .continuing(let started, let completes):
            guard operation == .none, let pending = state.pending else { return }
            // Best effort: only a commit, continue or skip that ends an operation of the kind that stopped completes
            // its entry. `Pending` records the kind only, so one aborted in a terminal and started again there as the
            // same kind is not told apart. Anything else that ended it (a hard reset, a discard) threw the operation
            // away: its before-snapshot no longer describes an undo.
            guard completes, succeeded, pending.operation == started else {
                state.pending = nil
                try? save(state)
                return
            }
            let names = pending.before.refs.map(\.name)
            let upstreams = Set(pending.before.refs.filter { $0.upstream != nil }.map(\.name))
            guard let after = try? await Self.capture(ops, names: names, upstreamOf: upstreams) else { return }
            append(Entry(
                id: UUID(), kind: pending.kind, title: pending.title, date: Date(), mode: pending.mode,
                before: pending.before, after: after, content: nil), to: &state)
        }
        try? save(state)
    }

    /// Forgets the pending operation (it was aborted).
    func clearPending() {
        guard var state = try? load(), state.pending != nil else { return }
        state.pending = nil
        try? save(state)
    }

    private func append(_ entry: Entry, to state: inout State) {
        state.undo.append(entry)
        if state.undo.count > limit { state.undo.removeFirst(state.undo.count - limit) }
        state.redo = []
        state.pending = nil
    }

    // MARK: - Undo and redo (inside the write lane)

    enum Direction { case undo, redo }

    /// Moves the repository from the entry's after-state back to its before-state (undo) or forward again (redo).
    func step(_ direction: Direction, ops: GitOperations) async throws -> Entry {
        var state = try load()
        guard let entry = direction == .undo ? state.undo.last : state.redo.last else {
            throw direction == .undo ? UndoError.nothingToUndo : UndoError.nothingToRedo
        }
        try entry.validate()
        try await entry.validateNames(ops)
        let (from, to) = direction == .undo ? (entry.after, entry.before) : (entry.before, entry.after)
        let names = to.refs.map(\.name)

        // Check everything first, so a refusal changes nothing.
        if try await RepoState.read(runner: ops.runner, cwd: ops.cwd, env: ops.env).isOperationInProgress {
            throw UndoError.operationInProgress
        }
        // `write-tree` fails on an index with conflicts (after a conflicting stash pop): not the recorded state.
        guard let current = try? await Self.capture(ops, names: names, upstreamOf: []),
            current.matches(from, ignoringIndex: entry.keepsIndex)
        else {
            throw UndoError.repositoryChanged
        }
        // The content's paths are top-level relative (`ops` may run in a subfolder).
        let root = entry.content == nil ? ops : try await Self.topLevel(ops).ops
        if let content = entry.content {
            let unchanged = direction == .undo
                ? try await Self.isDiscarded(content, ops: root) : try await Self.isPresent(content, ops: root)
            guard unchanged else { throw UndoError.repositoryChanged }
        }
        try await Self.requireObjects(of: to, content: direction == .undo ? entry.content : nil, ops: ops)

        let message = "Histq: \(direction == .undo ? "undo" : "redo") \(entry.kind.rawValue)"
        if direction == .redo, let content = entry.content {
            // Throw the content away again first, so the files are clean when the index moves on.
            try await Self.discard(content, ops: root)
        }
        if from.index != to.index {
            switch entry.mode {
            case .index: try await ops.exec(["read-tree", to.index])
            case .carry, .discard: try await ops.exec(["read-tree", "-m", "-u", from.index, to.index])
            }
        }
        try await Self.moveRefs(from: from, to: to, message: message, ops: ops)
        try await Self.moveHead(from: from.head, to: to.head, message: message, ops: ops)
        if direction == .undo, let content = entry.content {
            try await Self.restore(content, ops: root)
        }

        if direction == .undo {
            state.undo.removeLast()
            state.redo.append(entry)
        } else {
            state.redo.removeLast()
            state.undo.append(entry)
        }
        try save(state)
        return entry
    }

    // MARK: - Snapshots

    static func headRef(_ ops: GitOperations) async throws -> String? {
        let text = try await ops.exec(["symbolic-ref", "-q", "HEAD"], allowedExitCodes: [0, 1]).text
        return trimmed(text)
    }

    /// HEAD, the branches `names` (in that order) and the index. `upstreamOf` lists the branches whose upstream is
    /// recorded too. Throws when the index has conflicts (`write-tree` refuses).
    static func capture(_ ops: GitOperations, names: [String], upstreamOf: Set<String>) async throws -> Snapshot {
        let headRef = try await headRef(ops)
        let headCommit = trimmed(
            try await ops.exec(["rev-parse", "-q", "--verify", "HEAD"], allowedExitCodes: [0, 1]).text)
        var oids: [String: String] = [:]
        if !names.isEmpty {
            // Patterns match a ref or a folder of refs: keep exact names only.
            let output = try await ops.exec(
                ["for-each-ref", "--format=%(objectname) %(refname)", "--end-of-options"] + names).text
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 { oids[parts[1]] = parts[0] }
            }
        }
        var refs: [RefValue] = []
        for name in names {
            var upstream: Upstream?
            if upstreamOf.contains(name), oids[name] != nil, let short = name.dropFirstPrefix("refs/heads/") {
                let remote = try await config("branch.\(short).remote", ops)
                let merge = try await config("branch.\(short).merge", ops)
                // An upstream undo would refuse to write back (a URL as remote) is not recorded: the branch still
                // comes back, without it.
                if let remote, let merge, await isValidUpstream(Upstream(remote: remote, merge: merge), ops: ops) {
                    upstream = Upstream(remote: remote, merge: merge)
                }
            }
            refs.append(RefValue(name: name, oid: oids[name], upstream: upstream))
        }
        let index = try await ops.exec(["write-tree"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Snapshot(head: Head(ref: headRef, commit: headCommit), refs: refs, index: index)
    }

    /// An upstream remote that can only be read as a remote's name: `.` (a local branch's upstream) or
    /// `[A-Za-z0-9._-]+` without a leading `.` or `-` and without `..`, never a URL (a later fetch would use it) or an
    /// option.
    static func isPlainRemote(_ remote: String) -> Bool {
        if remote == "." { return true }
        let allowed = remote.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
        return allowed && !remote.isEmpty && !remote.hasPrefix(".") && !remote.hasPrefix("-") && !remote.contains("..")
    }

    /// An upstream undo may write back: a plain remote and a branch ref `git check-ref-format` accepts.
    static func isValidUpstream(_ upstream: Upstream, ops: GitOperations) async -> Bool {
        guard isPlainRemote(upstream.remote), upstream.merge.hasPrefix("refs/heads/") else { return false }
        return await ops.checkRefFormat(upstream.merge)
    }

    private static func config(_ key: String, _ ops: GitOperations) async throws -> String? {
        trimmed(try await ops.exec(["config", "--get", key], allowedExitCodes: [0, 1]).text)
    }

    /// Saves what a discard is about to throw away: tracked changes with `stash create` (which touches no ref),
    /// untracked files as blobs, every path recorded relative to the worktree's top level. Fails on an unborn branch
    /// (`stash create` needs a commit).
    static func captureContent(_ cwdOps: GitOperations, scope: ContentScope) async throws -> Content {
        let (ops, prefix) = try await topLevel(cwdOps)
        // `.` is the folder of `cwd` itself; git normalizes any other path joined to the prefix.
        func fromTop(_ path: String) -> String {
            path == "." ? (prefix.isEmpty ? "." : String(prefix.dropLast())) : prefix + path
        }
        let paths = scope.wholeWorktree ? ["."] : scope.paths.map(fromTop)
        let stash = paths.isEmpty ? nil : trimmed(try await ops.exec(["stash", "create"]).text)
        var untracked: [UntrackedFile] = []
        if let untrackedPaths = scope.untrackedPaths?.map(fromTop), !untrackedPaths.isEmpty {
            let listed = try await ops.exec(
                ["--literal-pathspecs", "ls-files", "-z", "--others", "--exclude-standard", "--"] + untrackedPaths)
            // A nested repository shows as `dir/`; `clean -fd` keeps it, so the journal does too.
            var files: [(path: String, kind: UntrackedFile.FileKind)] = []
            for path in listed.text.split(separator: "\0").map(String.init) where !path.hasSuffix("/") {
                var info = stat()
                guard lstat(ops.cwd.appending(path: path, directoryHint: .notDirectory).path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFLNK: files.append((path, .symlink))
                case S_IFREG: files.append((path, info.st_mode & 0o111 != 0 ? .executable : .regular))
                default: continue
                }
            }
            let blobs = try await hashes(of: files, write: true, ops: ops)
            untracked = zip(files, blobs).map { UntrackedFile(path: $0.path, blob: $1, kind: $0.kind) }
        }
        return Content(
            stash: stash, paths: paths, untracked: untracked, removesUntracked: scope.untrackedPaths != nil)
    }

    /// The same operations run from the worktree's top level, and the folder of `ops.cwd` inside it (`sub/`, or empty
    /// at the top). Inside the lane: only `exec` is called on the result.
    static func topLevel(_ ops: GitOperations) async throws -> (ops: GitOperations, prefix: String) {
        let lines = try await ops.exec(["rev-parse", "--show-toplevel", "--show-prefix"]).text
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let top = lines.first, !top.isEmpty else {
            throw GitError.other(exit: 0, stderrTail: "unexpected rev-parse output")
        }
        let root = GitOperations(
            runner: ops.runner, cwd: URL(filePath: top, directoryHint: .isDirectory), env: ops.env,
            networkEnv: ops.networkEnv, networkTimeout: ops.networkTimeout, journal: ops.journal)
        return (root, lines.count > 1 ? lines[1] : "")
    }

    // MARK: - Checks

    /// The after-state of a discard: the tracked paths match the index and the removed untracked files are gone.
    private static func isDiscarded(_ content: Content, ops: GitOperations) async throws -> Bool {
        if !content.paths.isEmpty {
            let diff = try await ops.exec(
                ["--literal-pathspecs", "diff", "--quiet", "--no-ext-diff", "--no-textconv", "--"] + content.paths,
                allowedExitCodes: [0, 1])
            if diff.exitCode != 0 { return false }
        }
        for file in content.untracked {
            var info = stat()
            if lstat(ops.cwd.appending(path: file.path).path, &info) == 0 { return false }
        }
        return true
    }

    /// The before-state of a discard: the tracked paths still hold the stashed content and the untracked files
    /// are back with the same bytes.
    private static func isPresent(_ content: Content, ops: GitOperations) async throws -> Bool {
        if !content.paths.isEmpty {
            let source = content.stash.map { [$0] } ?? []
            let diff = try await ops.exec(
                ["--literal-pathspecs", "diff", "--quiet", "--no-ext-diff", "--no-textconv"] + source + ["--"]
                    + content.paths,
                allowedExitCodes: [0, 1])
            if diff.exitCode != 0 { return false }
        }
        for file in content.untracked {
            var info = stat()
            guard lstat(ops.cwd.appending(path: file.path, directoryHint: .notDirectory).path, &info) == 0,
                info.st_mode & S_IFMT == (file.kind == .symlink ? S_IFLNK : S_IFREG)
            else { return false }
        }
        let files = content.untracked.map { (path: $0.path, kind: $0.kind) }
        return try await hashes(of: files, write: false, ops: ops) == content.untracked.map(\.blob)
    }

    /// The blob ids of worktree files (`write`: stored too). Regular files go to `hash-object --no-filters` (the
    /// bytes on disk, exactly as restore writes them back) in batches, so thousands of untracked files do not mean
    /// thousands of processes inside the write lane; a symlink is hashed as its target path, like git stores it.
    private static func hashes(
        of files: [(path: String, kind: UntrackedFile.FileKind)], write: Bool, ops: GitOperations
    ) async throws -> [String] {
        let flags = ["hash-object"] + (write ? ["-w"] : [])
        var blobs: [String?] = Array(repeating: nil, count: files.count)
        let regular = files.indices.filter { files[$0].kind != .symlink }
        for start in stride(from: 0, to: regular.count, by: 200) {
            let batch = Array(regular[start..<min(start + 200, regular.count)])
            let output = try await ops.exec(flags + ["--no-filters", "--"] + batch.map { files[$0].path }).text
            let ids = output.split(separator: "\n").map(String.init)
            guard ids.count == batch.count else { throw GitError.other(exit: 0, stderrTail: "unexpected hash-object output") }
            for (index, id) in zip(batch, ids) { blobs[index] = id }
        }
        for index in files.indices where files[index].kind == .symlink {
            let url = ops.cwd.appending(path: files[index].path, directoryHint: .notDirectory)
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            blobs[index] = trimmed(try await ops.exec(flags + ["--stdin"], stdin: Data(target.utf8)).text)
        }
        return blobs.map { $0 ?? "" }
    }

    /// Refuses when `git gc` pruned an object the target state needs.
    private static func requireObjects(of snapshot: Snapshot, content: Content?, ops: GitOperations) async throws {
        var oids = snapshot.refs.compactMap(\.oid) + [snapshot.index] + (snapshot.head.commit.map { [$0] } ?? [])
        if let content { oids += (content.stash.map { [$0] } ?? []) + content.untracked.map(\.blob) }
        let input = oids.map { $0 + "\n" }.joined()
        let output = try await ops.exec(["cat-file", "--batch-check"], stdin: Data(input.utf8)).text
        if output.split(separator: "\n").contains(where: { $0.hasSuffix(" missing") }) {
            throw UndoError.objectsMissing
        }
    }

    // MARK: - Moving refs, HEAD and files

    /// One `update-ref --stdin` transaction, each change checked against the current value; then the upstream of
    /// every branch that comes back, and the config section of every branch that goes away (as `git branch -d`).
    private static func moveRefs(from: Snapshot, to: Snapshot, message: String, ops: GitOperations) async throws {
        var commands = ""
        for ref in to.refs {
            let old = from.oid(of: ref.name)
            switch (old, ref.oid) {
            case (nil, nil): continue
            case (let old?, nil): commands += "delete \(ref.name) \(old)\n"
            case (nil, let new?): commands += "create \(ref.name) \(new)\n"
            case (let old?, let new?) where old != new: commands += "update \(ref.name) \(new) \(old)\n"
            default: continue
            }
        }
        guard !commands.isEmpty else { return }
        try await ops.exec(["update-ref", "-m", message, "--stdin"], stdin: Data(commands.utf8))

        for ref in to.refs where (from.oid(of: ref.name) == nil) != (ref.oid == nil) {
            guard let short = ref.name.dropFirstPrefix("refs/heads/") else { continue }
            if ref.oid == nil {
                // Best effort: the section may not exist.
                _ = try? await ops.exec(["config", "--remove-section", "branch.\(short)"], allowedExitCodes: [0, 1, 128])
            } else if let upstream = ref.upstream {
                try await ops.exec(["config", "branch.\(short).remote", upstream.remote])
                try await ops.exec(["config", "branch.\(short).merge", upstream.merge])
            }
        }
    }

    private static func moveHead(from: Head, to: Head, message: String, ops: GitOperations) async throws {
        if let ref = to.ref {
            if from.ref != ref { try await ops.exec(["symbolic-ref", "-m", message, "HEAD", ref]) }
        } else if let commit = to.commit, from.ref != nil || from.commit != commit {
            try await ops.exec(["update-ref", "--no-deref", "-m", message, "HEAD", commit])
        }
    }

    /// Undo of a discard: the tracked paths from the stash's tree, the untracked files from their blobs.
    private static func restore(_ content: Content, ops: GitOperations) async throws {
        if let stash = content.stash, !content.paths.isEmpty {
            try await ops.exec(
                ["--literal-pathspecs", "restore", "--source=\(stash)", "--worktree", "--"] + content.paths)
        }
        for file in content.untracked {
            let url = try safeFile(file.path, in: ops.cwd)
            let data = try await ops.exec(["cat-file", "blob", file.blob]).stdout
            switch file.kind {
            case .symlink:
                try FileManager.default.createSymbolicLink(
                    atPath: url.path, withDestinationPath: String(decoding: data, as: UTF8.self))
            case .regular, .executable:
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: file.kind == .executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            }
        }
    }

    /// Redo of a discard: the tracked paths from the index again, the recorded untracked files removed.
    private static func discard(_ content: Content, ops: GitOperations) async throws {
        if !content.paths.isEmpty {
            try await ops.exec(["--literal-pathspecs", "restore", "--worktree", "--"] + content.paths)
        }
        if content.removesUntracked {
            for file in content.untracked {
                try FileManager.default.removeItem(at: try safeFile(file.path, in: ops.cwd))
            }
        }
    }

    /// A recorded path that stays inside the worktree and out of every repository's `.git` (a nested one too): not
    /// absolute, no empty, `.` or `..` component, and no component that names `.git` on a case-insensitive file
    /// system (APFS and HFS+ fold case; HFS+ also ignores the invisible code points git's `is_hfs_dotgit` drops).
    static func isSafePath(_ path: String) -> Bool {
        let ignorable: [ClosedRange<UInt32>] = [0x200C...0x200F, 0x202A...0x202E, 0x206A...0x206F, 0xFEFF...0xFEFF]
        func isDotGit(_ part: Substring) -> Bool {
            let visible = part.unicodeScalars.filter { scalar in !ignorable.contains { $0.contains(scalar.value) } }
            return String(String.UnicodeScalarView(visible)).lowercased() == ".git"
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/")
            && !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty || isDotGit($0) })
    }

    /// The URL of a recorded path, inside `cwd`: an `isSafePath` path without a symlinked folder (each parent is
    /// checked with lstat from the worktree down and created when missing), so a journal file or a planted link
    /// cannot send a write elsewhere.
    static func safeFile(_ path: String, in cwd: URL) throws -> URL {
        guard isSafePath(path) else { throw UndoError.unsafePath(path) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        var folder = cwd
        for part in parts.dropLast() {
            folder = folder.appending(path: String(part), directoryHint: .isDirectory)
            var info = stat()
            if lstat(folder.path, &info) != 0 {
                guard errno == ENOENT, mkdir(folder.path, 0o755) == 0 else { throw UndoError.unsafePath(path) }
            } else if info.st_mode & S_IFMT != S_IFDIR {
                throw UndoError.unsafePath(path)
            }
        }
        return cwd.appending(path: path, directoryHint: .notDirectory)
    }

    static func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }
}

extension UndoJournal.Entry {
    /// The journal file lives outside the repository and could be edited: every ref, object id and HEAD target
    /// must look like what Histq writes before any of it reaches git.
    func validate() throws {
        func validObject(_ oid: String?) -> Bool { oid.map(GitOperations.isObjectID) ?? true }
        func validRef(_ name: String) -> Bool {
            name.hasPrefix("refs/heads/") && !name.unicodeScalars.contains {
                $0.value <= 0x20 || $0.value == 0x7F
            }
        }
        for snapshot in [before, after] {
            guard GitOperations.isObjectID(snapshot.index), validObject(snapshot.head.commit),
                snapshot.head.ref.map(validRef) ?? true,
                snapshot.refs.allSatisfy({ validRef($0.name) && validObject($0.oid) })
            else { throw UndoError.unreadableJournal }
        }
        for upstream in (before.refs + after.refs).compactMap(\.upstream) {
            guard UndoJournal.isPlainRemote(upstream.remote), upstream.merge.hasPrefix("refs/heads/") else {
                throw UndoError.unreadableJournal
            }
        }
        if let content {
            guard validObject(content.stash), content.untracked.allSatisfy({ GitOperations.isObjectID($0.blob) }) else {
                throw UndoError.unreadableJournal
            }
            // Checked before anything moves, so a refused path never leaves a half-done undo.
            if let unsafe = content.untracked.first(where: { !UndoJournal.isSafePath($0.path) }) {
                throw UndoError.unsafePath(unsafe.path)
            }
        }
    }

    /// The checks of `validate()` that need git: every branch is a name `git branch` accepts (its short name builds
    /// the `branch.<name>.*` config keys) and every upstream's `merge` passes `git check-ref-format`.
    func validateNames(_ ops: GitOperations) async throws {
        let snapshots = [before, after]
        let names = Set(snapshots.flatMap { snapshot in snapshot.refs.map(\.name) + [snapshot.head.ref].compactMap(\.self) })
        for name in names {
            guard let short = name.dropFirstPrefix("refs/heads/"), (try? await ops.validateBranchName(short)) != nil else {
                throw UndoError.unreadableJournal
            }
        }
        for upstream in snapshots.flatMap({ $0.refs.compactMap(\.upstream) }) {
            guard await UndoJournal.isValidUpstream(upstream, ops: ops) else { throw UndoError.unreadableJournal }
        }
    }
}

extension String {
    fileprivate func dropFirstPrefix(_ prefix: String) -> String? {
        guard utf8.starts(with: prefix.utf8) else { return nil }
        return String(decoding: utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    }
}
