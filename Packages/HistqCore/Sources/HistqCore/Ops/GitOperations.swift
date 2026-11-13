// Every user-initiated write of a repository (the gk command inventory): checkout, commit, stage, fetch,
// pull, push, branches, remotes, worktrees, merge/rebase/cherry-pick/revert/reset, stashes, tags, continue/abort/skip,
// clone and init. Each public operation takes the runner's `mutate` lane exactly once (compound operations
// run their steps inside that one lane; never call another public operation or `PatchBuilder.apply` from
// inside it: a nested `mutate` deadlocks).
//
// Safety: a user string never becomes an option. Paths go after `--` with `--literal-pathspecs` (no
// pathspec magic), revisions after `--end-of-options`, messages through stdin or `--message=`, new
// branch/tag/remote names are checked (no leading `-`, `git check-ref-format`; remote names
// `[A-Za-z0-9._-]+`), push refspecs are full refs (`refs/heads/x`, so a name can never mean `+force`), and
// `stash@{n}` is built from an `Int`. Merge, pull and revert pass `--no-edit`; continue/abort/skip run
// with `-c core.editor=true`, so git never waits for an editor.
//
// Undo: with a `journal`, the operations the journal can take back (commit, amend, checkout, reset, merge, rebase,
// cherry-pick, revert, local branch create/delete/rename, discard) are snapshotted before and after inside their
// own lane, so no other write can slip in between; `undo()` and `redo()` move between those snapshots.
import Foundation

public enum GitOperationError: Error, Equatable, Sendable {
    case invalidBranchName(String)
    case invalidTagName(String)
    case invalidRemoteName(String)
    case invalidRemoteURL(String)
    /// An expected object id (force-with-lease) that is not 4 to 64 hex digits.
    case invalidObjectID(String)
    /// A path operation got no paths (`clean --`/`reset --` without paths would touch everything).
    case noPaths
    case invalidStashIndex(Int)
    case invalidMainline(Int)
    /// `continue`/`abort`/`skip` asked with no operation in progress.
    case noOperationInProgress
    /// The operation has no such step (`git merge` has no `--skip`).
    case unsupported(String)
    /// A new worktree's folder that is relative, has `..`, control characters, a missing parent or already exists.
    case invalidWorktreePath(String)
    /// A path `git worktree list` does not have.
    case notAWorktree(String)
    /// The main worktree cannot be removed.
    case mainWorktree(String)
    /// The worktree the operations run in (removing it deletes the caller's folder).
    case currentWorktree(String)
}

public struct GitOperations: Sendable {
    public enum ResetMode: String, Sendable { case soft, mixed, hard }

    public enum PullMode: Sendable {
        /// Fast-forward when possible, else a merge commit (`--no-rebase --ff --no-edit`).
        case fastForward
        /// Refuse unless a fast-forward is possible (`--no-rebase --ff-only`).
        case fastForwardOnly
        /// `--rebase`.
        case rebase
    }

    /// Per-commit signing on top of the profile's `commit.gpgSign` default.
    public enum CommitSigning: Sendable {
        case profileDefault, sign, noSign
    }

    public let runner: GitRunner
    /// The worktree the operations run in.
    public let cwd: URL
    /// The write environment (`GitInvocation.environment(profile:base:)`): identity, signing, ssh.
    public let env: [String: String]
    /// The environment of network operations (fetch, pull, push and their compound steps). Defaults to
    /// `env`; a caller adds network-only settings (credentials) here.
    public let networkEnv: [String: String]
    /// The time limit of one network command (git is stopped after it).
    public let networkTimeout: Duration
    /// Records the undoable operations of this worktree; nil = no undo.
    public let journal: UndoJournal?

    public init(
        runner: GitRunner, cwd: URL, env: [String: String], networkEnv: [String: String]? = nil,
        networkTimeout: Duration = .seconds(600), journal: UndoJournal? = nil
    ) {
        self.runner = runner
        self.cwd = cwd
        self.env = env
        self.networkEnv = networkEnv ?? env
        self.networkTimeout = networkTimeout
        self.journal = journal
    }

    // MARK: - Checkout

    /// Switches to the local branch `name`.
    public func checkout(branch name: String) async throws {
        try await journaled(.checkout, "Checkout \(name)", mode: .carry) { ops in
            try await ops.exec(["checkout", "--end-of-options", name, "--"])
        }
    }

    /// Creates the local branch `localName` tracking `remoteBranch` (e.g. `origin/feature`) and switches to it.
    public func checkoutTracking(remoteBranch: String, as localName: String) async throws {
        try await validateBranchName(localName)
        try await journaled(.checkout, "Checkout \(localName)", mode: .carry, refs: ["refs/heads/\(localName)"]) { ops in
            try await ops.exec(["checkout", "--track", "-b", localName, "--end-of-options", remoteBranch, "--"])
        }
    }

    /// Detaches HEAD at `revision`.
    public func checkout(commit revision: String) async throws {
        try await journaled(.checkout, "Checkout \(Self.shortRevision(revision))", mode: .carry) { ops in
            try await ops.exec(["checkout", "--detach", "--end-of-options", revision, "--"])
        }
    }

    /// Replaces `paths` in the index and working tree with their content at `revision`.
    public func checkoutFiles(_ paths: [String], from revision: String) async throws {
        try requirePaths(paths)
        try await write(["--literal-pathspecs", "checkout", "--end-of-options", revision, "--"] + paths)
    }

    // MARK: - Commit

    /// Commits the index with `message` (passed on stdin, kept as written).
    public func commit(message: String, signing: CommitSigning = .profileDefault) async throws {
        try await journaled(.commit, "Commit \"\(Self.subject(message))\"", mode: .index, completesOperation: true) { ops in
            try await ops.exec(["commit", "--file=-"] + Self.signingFlags(signing), stdin: Data(message.utf8))
        }
    }

    /// Amends HEAD with the index; `message` nil keeps the current message.
    public func amend(message: String?, signing: CommitSigning = .profileDefault) async throws {
        let flags = ["commit", "--amend"] + Self.signingFlags(signing)
        try await journaled(.amend, "Amend last commit", mode: .index) { ops in
            if let message {
                try await ops.exec(flags + ["--file=-"], stdin: Data(message.utf8))
            } else {
                try await ops.exec(flags + ["--no-edit"])
            }
        }
    }

    // MARK: - Stage, unstage, discard

    /// Stages `paths` (new, modified and deleted files).
    public func stage(_ paths: [String]) async throws {
        try requirePaths(paths)
        try await write(["--literal-pathspecs", "add", "-A", "--"] + paths)
    }

    public func stageAll() async throws {
        try await write(["add", "-A"])
    }

    /// Resets the index entries of `paths` to HEAD (works on an unborn branch too).
    public func unstage(_ paths: [String]) async throws {
        try requirePaths(paths)
        try await write(["--literal-pathspecs", "reset", "-q", "--"] + paths)
    }

    public func unstageAll() async throws {
        try await write(["reset", "-q"])
    }

    /// Discards the unstaged changes of tracked `paths` (the working tree takes the index version).
    public func discard(_ paths: [String]) async throws {
        try requirePaths(paths)
        let content = UndoJournal.ContentScope(paths: paths, untrackedPaths: nil)
        try await journaled(.discard, "Discard changes", mode: .discard, content: content) { ops in
            try await ops.exec(["--literal-pathspecs", "restore", "--worktree", "--"] + paths)
        }
    }

    /// Deletes the untracked files or folders `paths`.
    public func removeUntracked(_ paths: [String]) async throws {
        try requirePaths(paths)
        let content = UndoJournal.ContentScope(paths: [], untrackedPaths: paths)
        try await journaled(.discard, "Delete untracked files", mode: .discard, content: content) { ops in
            try await ops.exec(["--literal-pathspecs", "clean", "-f", "-d", "-q", "--"] + paths)
        }
    }

    /// "Discard all unstaged": `restore .` (staged changes and untracked files stay).
    public func discardAllUnstaged() async throws {
        let content = UndoJournal.ContentScope(paths: ["."], untrackedPaths: nil)
        try await journaled(.discard, "Discard all unstaged changes", mode: .discard, content: content) { ops in
            try await ops.exec(["restore", "--worktree", "--", "."])
        }
    }

    /// "Discard all": `reset --hard` (index and tracked files back to HEAD), plus `clean -fd` when
    /// `includingUntracked`. The caller confirms first.
    public func discardAll(includingUntracked: Bool) async throws {
        // `reset --hard` covers the whole worktree, `clean` (no pathspec) only the folder of `cwd`.
        let content = UndoJournal.ContentScope(
            paths: ["."], untrackedPaths: includingUntracked ? ["."] : nil, wholeWorktree: true)
        try await journaled(.discard, "Discard all changes", mode: .discard, content: content) { ops in
            try await ops.exec(["reset", "-q", "--hard"])
            if includingUntracked { try await ops.exec(["clean", "-f", "-d", "-q"]) }
        }
    }

    // MARK: - Fetch, pull, push

    public func fetchAll(prune: Bool = true) async throws {
        try await write(["fetch", "--all"] + (prune ? ["--prune"] : []), network: true)
    }

    /// Pulls the current branch's upstream.
    public func pull(_ mode: PullMode) async throws {
        let flags: [String] = switch mode {
        case .fastForward: ["--no-rebase", "--ff", "--no-edit"]
        case .fastForwardOnly: ["--no-rebase", "--ff-only"]
        case .rebase: ["--rebase"]
        }
        try await write(["pull"] + flags, network: true)
    }

    /// Pushes the local `branch` to `remoteBranch` (default: the same name) on `remote`. `setUpstream`
    /// adds `-u`. `forceWithLease` is the sha the remote branch must still have
    /// (`--force-with-lease=refs/heads/<remoteBranch>:<sha>`); otherwise the push is refused
    /// (`GitError.nonFastForward`).
    public func push(
        branch: String, to remote: String, as remoteBranch: String? = nil, setUpstream: Bool = false,
        forceWithLease expected: String? = nil
    ) async throws {
        let target = "refs/heads/" + (remoteBranch ?? branch)
        var args = ["push"]
        if setUpstream { args.append("-u") }
        if let expected {
            guard Self.isObjectID(expected) else { throw GitOperationError.invalidObjectID(expected) }
            args.append("--force-with-lease=\(target):\(expected)")
        }
        try await write(args + ["--end-of-options", remote, "refs/heads/\(branch):\(target)"], network: true)
    }

    /// Mirrors every ref to `remote` (`push --mirror`: deletes remote refs missing here). The caller confirms.
    public func pushMirror(to remote: String) async throws {
        try await write(["push", "--mirror", "--end-of-options", remote], network: true)
    }

    // MARK: - Branches

    /// Creates `name` at `revision` (a commit or branch); `checkout` also switches to it.
    public func createBranch(_ name: String, from revision: String, checkout: Bool = false) async throws {
        try await validateBranchName(name)
        try await journaled(
            .createBranch, "Create branch \(name)", mode: checkout ? .carry : .index, refs: ["refs/heads/\(name)"]
        ) { ops in
            if checkout {
                try await ops.exec(["checkout", "-b", name, "--end-of-options", revision, "--"])
            } else {
                try await ops.exec(["branch", "--end-of-options", name, revision])
            }
        }
    }

    public func renameBranch(_ name: String, to newName: String) async throws {
        try await validateBranchName(newName)
        try await journaled(
            .renameBranch, "Rename branch \(name) to \(newName)", mode: .index,
            refs: ["refs/heads/\(name)", "refs/heads/\(newName)"]
        ) { ops in
            try await ops.exec(["branch", "-m", "--end-of-options", name, newName])
        }
    }

    /// `-d` (refuses an unmerged branch) or `-D` with `force`.
    public func deleteBranch(_ name: String, force: Bool = false) async throws {
        try await journaled(.deleteBranch, "Delete branch \(name)", mode: .index, refs: ["refs/heads/\(name)"]) { ops in
            try await ops.exec(["branch", force ? "-D" : "-d", "--end-of-options", name])
        }
    }

    /// Renames a branch on `remote`: pushes `<remote>/<name>` as `newName`, then deletes `name` there.
    public func renameRemoteBranch(_ name: String, to newName: String, on remote: String) async throws {
        try await validateBranchName(newName)
        try await lane { ops in
            try await ops.exec(
                ["push", "--end-of-options", remote, "refs/remotes/\(remote)/\(name):refs/heads/\(newName)"],
                network: true)
            try await ops.exec(["push", "--end-of-options", remote, ":refs/heads/\(name)"], network: true)
        }
    }

    public func deleteRemoteBranch(_ name: String, on remote: String) async throws {
        try await write(["push", "--end-of-options", remote, ":refs/heads/\(name)"], network: true)
    }

    /// Sets the upstream of `branch` to `upstream` (e.g. `origin/main`).
    public func setUpstream(of branch: String, to upstream: String) async throws {
        try await write(["branch", "--set-upstream-to=\(upstream)", "--end-of-options", branch])
    }

    // MARK: - Remotes

    public func addRemote(_ name: String, url: String) async throws {
        try await validateRemoteName(name)
        try Self.validateRemoteURL(url)
        try await write(["remote", "add", "--end-of-options", name, url])
    }

    public func removeRemote(_ name: String) async throws {
        try await write(["remote", "remove", "--end-of-options", name])
    }

    public func renameRemote(_ name: String, to newName: String) async throws {
        try await validateRemoteName(newName)
        try await write(["remote", "rename", "--end-of-options", name, newName])
    }

    public func setRemoteURL(_ name: String, url: String) async throws {
        try Self.validateRemoteURL(url)
        try await write(["remote", "set-url", "--end-of-options", name, url])
    }

    // MARK: - Worktrees

    /// What a new worktree checks out.
    public enum WorktreeSource: Sendable, Equatable {
        /// An existing local branch by its short name (`develop`); git refuses one checked out elsewhere.
        case branch(String)
        /// A commit by its full or abbreviated object id (resolve a name with `rev-parse` first): detached, or the
        /// start of a new branch.
        case commit(String)
    }

    /// Adds a worktree at `path` (absolute; its parent must exist and it must not) checking out `source`, or a new
    /// branch `newBranch` started there. Not journaled: undo never touches another worktree's files.
    public func addWorktree(at path: String, from source: WorktreeSource, newBranch: String? = nil) async throws {
        if let newBranch { try await validateBranchName(newBranch) }
        if case .branch(let name) = source {
            // A short name: `refs/heads/x` would be taken as a commit and detach. Checked as a ref that exists, so a
            // name git would DWIM into a remote-tracking branch or a commit never gets that far.
            guard Self.isSafeName(name), await checkRefFormat("refs/heads/\(name)") else {
                throw GitOperationError.invalidBranchName(name)
            }
        }
        let args = try Self.addWorktreeArguments(path: path, source: source, newBranch: newBranch)
        try await lane { ops in
            if case .branch(let name) = source {
                let exists = try await ops.exec(
                    ["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], allowedExitCodes: [0, 1])
                guard exists.exitCode == 0 else { throw GitOperationError.invalidBranchName(name) }
            }
            try await ops.exec(args)
        }
    }

    /// `worktree add [-b <new> | --detach] --end-of-options <path> <commit-ish>`: the path and the revision can never
    /// be read as options. Throws for a bad path, a commit that is not an object id, or a new branch name with a
    /// leading `-` (`addWorktree` also checks it with `check-ref-format`).
    public static func addWorktreeArguments(path: String, source: WorktreeSource, newBranch: String?) throws
        -> [String]
    {
        try validateWorktreePath(path)
        var args = ["worktree", "add"]
        if let newBranch {
            guard isSafeName(newBranch) else { throw GitOperationError.invalidBranchName(newBranch) }
            args += ["-b", newBranch]
        }
        let revision: String
        switch source {
        case .branch(let name):
            guard isSafeName(name) else { throw GitOperationError.invalidBranchName(name) }
            revision = name
        case .commit(let id):
            guard isObjectID(id) else { throw GitOperationError.invalidObjectID(id) }
            if newBranch == nil { args.append("--detach") }
            revision = id
        }
        return args + ["--end-of-options", path, revision]
    }

    /// A new worktree's folder: absolute, not `/`, no control characters, no `.`/`..` component, its parent an
    /// existing folder and itself not there yet.
    public static func validateWorktreePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"), path.count > 1, !path.hasSuffix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw GitOperationError.invalidWorktreePath(path) }
        var isFolder: ObjCBool = false
        let parent = (path as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isFolder), isFolder.boolValue,
              (try? FileManager.default.attributesOfItem(atPath: path)) == nil
        else { throw GitOperationError.invalidWorktreePath(path) }
    }

    /// Removes the linked worktree `path` (as `git worktree list` gives it) and its folder. Refuses the main worktree
    /// and the one these operations run in (git would delete the folder under the caller), and any path the list,
    /// read in the same lane, does not have. Git refuses a worktree with changes or untracked files unless `force`;
    /// pass it only after the user chose to lose them.
    public func removeWorktree(_ path: String, force: Bool = false) async throws {
        try await lane { ops in
            let listed = try await ops.exec(StashWorktreeReader.worktreeArguments).stdout
            guard let worktree = StashWorktreeReader.parseWorktrees(listed).first(where: { $0.path == path }) else {
                throw GitOperationError.notAWorktree(path)
            }
            guard !worktree.isMain else { throw GitOperationError.mainWorktree(path) }
            let target = URL(filePath: path).resolvingSymlinksInPath().path
            let here = ops.cwd.resolvingSymlinksInPath().path
            guard here != target, !here.hasPrefix(target.hasSuffix("/") ? target : target + "/") else {
                throw GitOperationError.currentWorktree(path)
            }
            try await ops.exec(Self.removeWorktreeArguments(path: path, force: force))
        }
    }

    /// `worktree remove [--force] --end-of-options <path>`.
    public static func removeWorktreeArguments(path: String, force: Bool) -> [String] {
        ["worktree", "remove"] + (force ? ["--force"] : []) + ["--end-of-options", path]
    }

    /// Drops the records of worktrees whose folder is gone (`git worktree prune`).
    public func pruneWorktrees() async throws {
        try await write(["worktree", "prune"])
    }

    // MARK: - Merge, rebase, cherry-pick, revert, reset

    /// Merges `revision` into the current branch. A conflict throws `GitError.conflict` and leaves the
    /// merge in progress (see `RepoState`).
    public func merge(_ revision: String, noFastForward: Bool = false) async throws {
        try await journaled(.merge, "Merge \(Self.shortRevision(revision))", mode: .carry) { ops in
            try await ops.exec(["merge", "--no-edit"] + (noFastForward ? ["--no-ff"] : []) + ["--end-of-options", revision])
        }
    }

    /// Rebases the current branch onto `upstream`.
    public func rebase(onto upstream: String) async throws {
        try await journaled(.rebase, "Rebase onto \(Self.shortRevision(upstream))", mode: .carry) { ops in
            try await ops.exec(["rebase", "--end-of-options", upstream])
        }
    }

    /// Fast-forwards the local `branch` to `source`, a full ref (`refs/heads/x`, `refs/remotes/origin/x`). Refused
    /// (`GitError.nonFastForward`) unless `branch` is an ancestor of `source`. The checked-out branch moves with
    /// `merge --ff-only` (its index and files follow); another branch with a local `fetch . <source>:refs/heads/<branch>`,
    /// which also refuses a branch checked out in another worktree.
    public func fastForward(_ branch: String, to source: String) async throws {
        try await validateBranchName(branch)
        guard source.hasPrefix("refs/"), await checkRefFormat(source) else {
            throw GitOperationError.invalidBranchName(source)
        }
        try await lane { ops in
            let head = try await ops.exec(["symbolic-ref", "-q", "HEAD"], allowedExitCodes: [0, 1])
            if head.text.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/\(branch)" {
                try await ops.exec(["merge", "--ff-only", "--end-of-options", source])
            } else {
                try await ops.exec(
                    ["fetch", "--no-write-fetch-head", "--end-of-options", ".", "\(source):refs/heads/\(branch)"])
            }
        }
    }

    /// Cherry-picks `commits` in order; `mainline` (1 or 2) picks a merge relative to that parent.
    public func cherryPick(_ commits: [String], mainline: Int? = nil) async throws {
        guard !commits.isEmpty else { throw GitOperationError.unsupported("cherry-pick without commits") }
        let flags = try Self.mainlineFlags(mainline)
        let title = commits.count == 1 ? "Cherry-pick \(Self.shortRevision(commits[0]))" : "Cherry-pick \(commits.count) commits"
        try await journaled(.cherryPick, title, mode: .carry) { ops in
            try await ops.exec(["cherry-pick"] + flags + ["--end-of-options"] + commits)
        }
    }

    /// Reverts `commit`; a merge needs `mainline` (1 = keep the first parent's side, 2 = the second's).
    public func revert(_ commit: String, mainline: Int? = nil) async throws {
        let flags = try Self.mainlineFlags(mainline)
        try await journaled(.revert, "Revert \(Self.shortRevision(commit))", mode: .carry) { ops in
            try await ops.exec(["revert", "--no-edit"] + flags + ["--end-of-options", commit])
        }
    }

    /// Moves the current branch to `revision`: soft keeps index and files, mixed keeps files, hard resets both.
    public func reset(to revision: String, mode: ResetMode) async throws {
        // A hard reset throws the working tree's changes away: the journal keeps them like a discard.
        let content: UndoJournal.ContentScope? =
            mode == .hard ? .init(paths: ["."], untrackedPaths: nil, wholeWorktree: true) : nil
        try await journaled(
            .reset, "Reset to \(Self.shortRevision(revision))", mode: mode == .hard ? .discard : .index, content: content
        ) { ops in
            try await ops.exec(["reset", "-q", "--\(mode.rawValue)", "--end-of-options", revision, "--"])
        }
    }

    /// "Uncommit": soft reset to `HEAD~1` (the commit's changes stay staged).
    public func uncommit() async throws {
        try await reset(to: "HEAD~1", mode: .soft)
    }

    // MARK: - Continue, abort, skip

    /// A continue that completes the operation makes it undoable as a whole (back to before it started).
    public func continueOperation(_ operation: RepoState.Operation) async throws {
        let args = try Self.sequencerArguments(operation, "--continue")
        try await journaled(Self.journalKind(operation), "Continue", mode: .carry, completesOperation: true) { ops in
            try await ops.exec(args)
        }
    }

    public func abortOperation(_ operation: RepoState.Operation) async throws {
        let args = try Self.sequencerArguments(operation, "--abort")
        try await lane { ops in
            try await ops.exec(args)
            ops.journal?.clearPending()
        }
    }

    /// Skips the current commit of a rebase, cherry-pick or revert (`git merge` has no `--skip`).
    public func skipOperation(_ operation: RepoState.Operation) async throws {
        if operation == .merge { throw GitOperationError.unsupported("git merge has no --skip") }
        let args = try Self.sequencerArguments(operation, "--skip")
        try await journaled(Self.journalKind(operation), "Skip", mode: .carry, completesOperation: true) { ops in
            try await ops.exec(args)
        }
    }

    // MARK: - Stashes

    /// Stashes the working tree and index (`-u`: untracked files too).
    public func stashPush(message: String? = nil, includeUntracked: Bool = true) async throws {
        try await write(
            ["stash", "push"] + (includeUntracked ? ["-u"] : []) + (message.map { ["--message=\($0)"] } ?? []))
    }

    public func stashPop(_ index: Int) async throws {
        try await write(["stash", "pop", "--end-of-options", try Self.stashSelector(index)])
    }

    public func stashApply(_ index: Int) async throws {
        try await write(["stash", "apply", "--end-of-options", try Self.stashSelector(index)])
    }

    public func stashDrop(_ index: Int) async throws {
        try await write(["stash", "drop", "--end-of-options", try Self.stashSelector(index)])
    }

    // MARK: - Tags

    /// A lightweight tag, or an annotated one when `message` is given (passed on stdin).
    public func createTag(_ name: String, at revision: String, message: String? = nil) async throws {
        try await validateTagName(name)
        if let message {
            try await write(["tag", "-a", "--file=-", "--end-of-options", name, revision], stdin: Data(message.utf8))
        } else {
            try await write(["tag", "--end-of-options", name, revision])
        }
    }

    public func deleteTag(_ name: String) async throws {
        try await write(["tag", "-d", "--end-of-options", name])
    }

    public func pushTag(_ name: String, to remote: String) async throws {
        try await write(["push", "--end-of-options", remote, "refs/tags/\(name):refs/tags/\(name)"], network: true)
    }

    public func deleteRemoteTag(_ name: String, on remote: String) async throws {
        try await write(["push", "--end-of-options", remote, ":refs/tags/\(name)"], network: true)
    }

    // MARK: - Clone and init

    /// Clones `url` into `destination` (which must not exist; its parent must), reporting git's
    /// `--progress` lines (stderr, split on `\r` and `\n`) as they arrive. `env` is the write environment
    /// plus any network settings. Cancelling the task stops git, and so does `timeout` (1 h by default;
    /// nil = no limit, for huge repos).
    public static func clone(
        url: String, into destination: URL, runner: GitRunner, env: [String: String],
        timeout: Duration? = .seconds(3600),
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        try validateRemoteURL(url)
        let parent = destination.deletingLastPathComponent()
        try await runner.mutate {
            let lines = await runner.stream(
                ["clone", "--progress", "--", url, destination.path], cwd: parent, env: env, timeout: timeout)
            for try await line in lines where line.source == .stderr {
                progress(line.text)
            }
            // A cancelled stream finishes without an error.
            try Task.checkCancellation()
        }
    }

    /// Creates an empty repository at `destination` (created if missing; its parent must exist).
    public static func initRepository(at destination: URL, runner: GitRunner, env: [String: String]) async throws {
        let parent = destination.deletingLastPathComponent()
        _ = try await runner.mutate {
            try await runner.run(["init", "-q", "--", destination.path], cwd: parent, env: env)
        }
    }

    // MARK: - Undo and redo

    /// Puts the repository back in the state before the last journaled operation and returns that operation.
    /// Throws `UndoError` (`.repositoryChanged` when something else changed HEAD, a touched branch, the index or
    /// the discarded files since; `.objectsMissing` after `git gc` pruned what it needs).
    @discardableResult
    public func undo() async throws -> UndoJournal.Entry {
        guard let journal else { throw UndoError.noJournal }
        return try await lane { ops in try await journal.step(.undo, ops: ops) }
    }

    /// Replays the last undone operation's after-state and returns that operation. Throws like `undo()`.
    @discardableResult
    public func redo() async throws -> UndoJournal.Entry {
        guard let journal else { throw UndoError.noJournal }
        return try await lane { ops in try await journal.step(.redo, ops: ops) }
    }

    // MARK: - Validation

    /// A new local branch name: not empty, no leading `-`, not `HEAD`, and `refs/heads/<name>` passes
    /// `git check-ref-format`.
    public func validateBranchName(_ name: String) async throws {
        guard Self.isSafeName(name), name != "HEAD", await checkRefFormat("refs/heads/\(name)") else {
            throw GitOperationError.invalidBranchName(name)
        }
    }

    /// A new tag name: not empty, no leading `-`, and `refs/tags/<name>` passes `git check-ref-format`.
    public func validateTagName(_ name: String) async throws {
        guard Self.isSafeName(name), await checkRefFormat("refs/tags/\(name)") else {
            throw GitOperationError.invalidTagName(name)
        }
    }

    /// A new remote name: `[A-Za-z0-9._-]+`, no leading `-`, and `refs/remotes/<name>/x` passes
    /// `git check-ref-format` (no `..`, no leading `.`, no `.lock` suffix).
    public func validateRemoteName(_ name: String) async throws {
        let allowed = name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
        guard Self.isSafeName(name), allowed, await checkRefFormat("refs/remotes/\(name)/x") else {
            throw GitOperationError.invalidRemoteName(name)
        }
    }

    /// A remote URL or path: not empty, no leading `-` (ssh/transport option injection), no control characters.
    public static func validateRemoteURL(_ url: String) throws {
        guard !url.isEmpty, !url.hasPrefix("-"),
            !url.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw GitOperationError.invalidRemoteURL(url) }
    }

    /// 4 to 64 ASCII hex digits.
    public static func isObjectID(_ text: String) -> Bool {
        (4...64).contains(text.utf8.count)
            && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }

    // MARK: - Helpers

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-")
    }

    func checkRefFormat(_ ref: String) async -> Bool {
        let result = try? await runner.run(["check-ref-format", ref], cwd: cwd, env: env, allowedExitCodes: [0, 1])
        return result?.exitCode == 0
    }

    private func requirePaths(_ paths: [String]) throws {
        if paths.isEmpty { throw GitOperationError.noPaths }
    }

    private static func signingFlags(_ signing: CommitSigning) -> [String] {
        switch signing {
        case .profileDefault: []
        case .sign: ["--gpg-sign"]
        case .noSign: ["--no-gpg-sign"]
        }
    }

    private static func mainlineFlags(_ mainline: Int?) throws -> [String] {
        guard let mainline else { return [] }
        guard mainline >= 1 else { throw GitOperationError.invalidMainline(mainline) }
        return ["-m", String(mainline)]
    }

    private static func stashSelector(_ index: Int) throws -> String {
        guard index >= 0 else { throw GitOperationError.invalidStashIndex(index) }
        return "stash@{\(index)}"
    }

    static func sequencerArguments(_ operation: RepoState.Operation, _ step: String) throws -> [String] {
        let verb: String = switch operation {
        case .none: throw GitOperationError.noOperationInProgress
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        }
        return ["-c", "core.editor=true", verb, step]
    }

    /// Runs an undoable operation in the lane between the journal's before- and after-snapshots (when there is a
    /// journal). `refs` are the branches it creates, deletes or renames (the journal adds HEAD's branch itself).
    /// `completesOperation`: a commit, continue or skip, which may complete a merge, rebase, cherry-pick or revert
    /// that stopped earlier (it then becomes undoable as a whole).
    func journaled(
        _ kind: UndoJournal.Kind, _ title: String, mode: UndoJournal.Mode, refs: [String] = [],
        content: UndoJournal.ContentScope? = nil, completesOperation: Bool = false,
        _ body: @escaping @Sendable (GitOperations) async throws -> Void
    ) async throws {
        guard let journal else { return try await lane(body) }
        try await lane { ops in
            let start = await journal.begin(ops, refs: refs, content: content, completesOperation: completesOperation)
            do {
                try await body(ops)
            } catch {
                if let start {
                    await journal.finish(start, kind: kind, title: title, mode: mode, refs: refs, succeeded: false, ops: ops)
                }
                throw error
            }
            if let start {
                await journal.finish(start, kind: kind, title: title, mode: mode, refs: refs, succeeded: true, ops: ops)
            }
        }
    }

    private static func journalKind(_ operation: RepoState.Operation) -> UndoJournal.Kind {
        switch operation {
        case .none, .merge: .merge
        case .rebase: .rebase
        case .cherryPick: .cherryPick
        case .revert: .revert
        }
    }

    /// The first line of a commit message, cut for a menu title.
    static func subject(_ message: String) -> String {
        let line = message.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.count > 50 ? String(line.prefix(49)) + "…" : line
    }

    /// An object id cut to 7 digits for a title; names stay as they are.
    static func shortRevision(_ revision: String) -> String {
        isObjectID(revision) && revision.count > 7 ? String(revision.prefix(7)) : revision
    }

    /// One write in the lane.
    @discardableResult
    private func write(_ args: [String], stdin: Data? = nil, network: Bool = false) async throws -> GitResult {
        try await lane { ops in try await ops.exec(args, stdin: stdin, network: network) }
    }

    /// Runs `body` in the runner's write lane. `body` must only call `exec`, never another public operation.
    func lane<T: Sendable>(_ body: @escaping @Sendable (GitOperations) async throws -> T) async throws -> T {
        let ops = self
        return try await runner.mutate { try await body(ops) }
    }

    /// Runs one command without taking the lane: only call it from inside `lane`. `extraEnv` adds to the
    /// environment of this one command (the interactive rebase's sequence editor).
    @discardableResult
    func exec(
        _ args: [String], stdin: Data? = nil, network: Bool = false, allowedExitCodes: Set<Int32> = [0],
        extraEnv: [String: String] = [:]
    ) async throws -> GitResult {
        try await runner.run(
            args, cwd: cwd, env: (network ? networkEnv : env).merging(extraEnv) { $1 }, stdin: stdin,
            timeout: network ? networkTimeout : nil, allowedExitCodes: allowedExitCodes)
    }
}
