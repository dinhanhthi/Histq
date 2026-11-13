// Every user-initiated write of a repository (the gk command inventory): checkout, commit, stage, fetch,
// pull, push, branches, remotes, merge/rebase/cherry-pick/revert/reset, stashes, tags, continue/abort/skip,
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

    public init(
        runner: GitRunner, cwd: URL, env: [String: String], networkEnv: [String: String]? = nil,
        networkTimeout: Duration = .seconds(600)
    ) {
        self.runner = runner
        self.cwd = cwd
        self.env = env
        self.networkEnv = networkEnv ?? env
        self.networkTimeout = networkTimeout
    }

    // MARK: - Checkout

    /// Switches to the local branch `name`.
    public func checkout(branch name: String) async throws {
        try await write(["checkout", "--end-of-options", name, "--"])
    }

    /// Creates the local branch `localName` tracking `remoteBranch` (e.g. `origin/feature`) and switches to it.
    public func checkoutTracking(remoteBranch: String, as localName: String) async throws {
        try await validateBranchName(localName)
        try await write(["checkout", "--track", "-b", localName, "--end-of-options", remoteBranch, "--"])
    }

    /// Detaches HEAD at `revision`.
    public func checkout(commit revision: String) async throws {
        try await write(["checkout", "--detach", "--end-of-options", revision, "--"])
    }

    /// Replaces `paths` in the index and working tree with their content at `revision`.
    public func checkoutFiles(_ paths: [String], from revision: String) async throws {
        try requirePaths(paths)
        try await write(["--literal-pathspecs", "checkout", "--end-of-options", revision, "--"] + paths)
    }

    // MARK: - Commit

    /// Commits the index with `message` (passed on stdin, kept as written).
    public func commit(message: String, signing: CommitSigning = .profileDefault) async throws {
        try await write(["commit", "--file=-"] + Self.signingFlags(signing), stdin: Data(message.utf8))
    }

    /// Amends HEAD with the index; `message` nil keeps the current message.
    public func amend(message: String?, signing: CommitSigning = .profileDefault) async throws {
        let flags = ["commit", "--amend"] + Self.signingFlags(signing)
        if let message {
            try await write(flags + ["--file=-"], stdin: Data(message.utf8))
        } else {
            try await write(flags + ["--no-edit"])
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
        try await write(["--literal-pathspecs", "restore", "--worktree", "--"] + paths)
    }

    /// Deletes the untracked files or folders `paths`.
    public func removeUntracked(_ paths: [String]) async throws {
        try requirePaths(paths)
        try await write(["--literal-pathspecs", "clean", "-f", "-d", "-q", "--"] + paths)
    }

    /// "Discard all unstaged": `restore .` (staged changes and untracked files stay).
    public func discardAllUnstaged() async throws {
        try await write(["restore", "--worktree", "--", "."])
    }

    /// "Discard all": `reset --hard` (index and tracked files back to HEAD), plus `clean -fd` when
    /// `includingUntracked`. The caller confirms first.
    public func discardAll(includingUntracked: Bool) async throws {
        try await lane { ops in
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
        if checkout {
            try await write(["checkout", "-b", name, "--end-of-options", revision, "--"])
        } else {
            try await write(["branch", "--end-of-options", name, revision])
        }
    }

    public func renameBranch(_ name: String, to newName: String) async throws {
        try await validateBranchName(newName)
        try await write(["branch", "-m", "--end-of-options", name, newName])
    }

    /// `-d` (refuses an unmerged branch) or `-D` with `force`.
    public func deleteBranch(_ name: String, force: Bool = false) async throws {
        try await write(["branch", force ? "-D" : "-d", "--end-of-options", name])
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

    // MARK: - Merge, rebase, cherry-pick, revert, reset

    /// Merges `revision` into the current branch. A conflict throws `GitError.conflict` and leaves the
    /// merge in progress (see `RepoState`).
    public func merge(_ revision: String, noFastForward: Bool = false) async throws {
        try await write(["merge", "--no-edit"] + (noFastForward ? ["--no-ff"] : []) + ["--end-of-options", revision])
    }

    /// Rebases the current branch onto `upstream`.
    public func rebase(onto upstream: String) async throws {
        try await write(["rebase", "--end-of-options", upstream])
    }

    /// Cherry-picks `commits` in order; `mainline` (1 or 2) picks a merge relative to that parent.
    public func cherryPick(_ commits: [String], mainline: Int? = nil) async throws {
        guard !commits.isEmpty else { throw GitOperationError.unsupported("cherry-pick without commits") }
        try await write(["cherry-pick"] + (try Self.mainlineFlags(mainline)) + ["--end-of-options"] + commits)
    }

    /// Reverts `commit`; a merge needs `mainline` (1 = keep the first parent's side, 2 = the second's).
    public func revert(_ commit: String, mainline: Int? = nil) async throws {
        try await write(["revert", "--no-edit"] + (try Self.mainlineFlags(mainline)) + ["--end-of-options", commit])
    }

    /// Moves the current branch to `revision`: soft keeps index and files, mixed keeps files, hard resets both.
    public func reset(to revision: String, mode: ResetMode) async throws {
        try await write(["reset", "-q", "--\(mode.rawValue)", "--end-of-options", revision, "--"])
    }

    /// "Uncommit": soft reset to `HEAD~1` (the commit's changes stay staged).
    public func uncommit() async throws {
        try await reset(to: "HEAD~1", mode: .soft)
    }

    // MARK: - Continue, abort, skip

    public func continueOperation(_ operation: RepoState.Operation) async throws {
        try await write(try Self.sequencerArguments(operation, "--continue"))
    }

    public func abortOperation(_ operation: RepoState.Operation) async throws {
        try await write(try Self.sequencerArguments(operation, "--abort"))
    }

    /// Skips the current commit of a rebase, cherry-pick or revert (`git merge` has no `--skip`).
    public func skipOperation(_ operation: RepoState.Operation) async throws {
        if operation == .merge { throw GitOperationError.unsupported("git merge has no --skip") }
        try await write(try Self.sequencerArguments(operation, "--skip"))
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

    private func checkRefFormat(_ ref: String) async -> Bool {
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

    /// One write in the lane.
    @discardableResult
    private func write(_ args: [String], stdin: Data? = nil, network: Bool = false) async throws -> GitResult {
        try await lane { ops in try await ops.exec(args, stdin: stdin, network: network) }
    }

    /// Runs `body` in the runner's write lane. `body` must only call `exec`, never another public operation.
    private func lane<T: Sendable>(_ body: @escaping @Sendable (GitOperations) async throws -> T) async throws -> T {
        let ops = self
        return try await runner.mutate { try await body(ops) }
    }

    /// Runs one command without taking the lane: only call it from inside `lane`.
    @discardableResult
    private func exec(_ args: [String], stdin: Data? = nil, network: Bool = false) async throws -> GitResult {
        try await runner.run(
            args, cwd: cwd, env: network ? networkEnv : env, stdin: stdin, timeout: network ? networkTimeout : nil)
    }
}
