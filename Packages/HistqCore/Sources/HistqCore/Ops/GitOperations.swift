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
// Token: with a `credential`, each network operation asks `GitInvocation.networkToken` first (inside its lane, for
// the remotes it contacts) and gets the GitHub token only when the gate lets it; see `networkExec`.
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
    /// A `fetchRefspec` refspec that is not `<remote ref>:<new local branch>` (a force `+`, an option, a pattern).
    case invalidRefspec(String)
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

/// A network command that failed to sign in after the token gate kept the GitHub token back for `reason`; `error` is
/// git's own failure.
public struct NetworkTokenWithheld: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The repository's own config sets these network keys.
        case repoNetworkConfig(keys: [String])
        /// The repository has submodules and these recursion keys are on.
        case submoduleRecursion(keys: [String])
    }

    public let reason: Reason
    public let error: GitError

    public init(reason: Reason, error: GitError) {
        self.reason = reason
        self.error = error
    }
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

    /// The profile's GitHub token and what the token gate needs to decide, command by command, whether git gets it.
    public struct NetworkCredential: Sendable {
        public var profile: Profile?
        public var base: [String: String]
        public var token: String

        public init(profile: Profile?, base: [String: String], token: String) {
            self.profile = profile
            self.base = base
            self.token = token
        }
    }

    public let runner: GitRunner
    /// The worktree the operations run in.
    public let cwd: URL
    /// The write environment (`GitInvocation.environment(profile:base:)`): identity, signing, ssh.
    public let env: [String: String]
    /// The environment of network operations (fetch, pull, push and their compound steps) that do not get the
    /// token. Defaults to `env`.
    public let networkEnv: [String: String]
    /// The token for network operations that pass the gate (`networkExec`); nil = never a token.
    public let credential: NetworkCredential?
    /// The time limit of one network command (git is stopped after it).
    public let networkTimeout: Duration
    /// Records the undoable operations of this worktree; nil = no undo.
    public let journal: UndoJournal?

    public init(
        runner: GitRunner, cwd: URL, env: [String: String], networkEnv: [String: String]? = nil,
        credential: NetworkCredential? = nil, networkTimeout: Duration = .seconds(600), journal: UndoJournal? = nil
    ) {
        self.runner = runner
        self.cwd = cwd
        self.env = env
        self.networkEnv = networkEnv ?? env
        self.credential = credential
        self.networkTimeout = networkTimeout
        self.journal = journal
    }

    /// The usual setup for `profile`: `env` (and `networkEnv`) is its write environment, and `token` goes only to the
    /// network operations the gate lets have it.
    public init(
        runner: GitRunner, cwd: URL, profile: Profile?, base: [String: String], token: String? = nil,
        networkTimeout: Duration = .seconds(600), journal: UndoJournal? = nil
    ) {
        self.init(
            runner: runner, cwd: cwd, env: GitInvocation.environment(profile: profile, base: base, access: .write),
            credential: token.map { NetworkCredential(profile: profile, base: base, token: $0) },
            networkTimeout: networkTimeout, journal: journal)
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

    /// `fetch --all`, with the token only when every remote passes the gate (all or nothing: fetching the remotes
    /// in two groups would mean redoing `skipFetchAll`, remote groups and partial failures); otherwise without it.
    public func fetchAll(prune: Bool = true) async throws {
        try await lane { ops in
            // Listed for the gate alone: without a token it has nothing to decide.
            let remotes = ops.credential == nil
                ? []
                : try? await GitInvocation.remoteNames(runner: ops.runner, cwd: ops.cwd, env: ops.env)
            try await ops.networkExec(
                ["fetch", "--all"] + (prune ? ["--prune"] : []), target: remotes.map { .fetch(remotes: $0) })
        }
    }

    /// Fetches one ref of `remote` into a local branch, never forced: `refspec` is `<ref>:<branch>`, e.g.
    /// `pull/12/head:pr/12` (a GitHub pull request's head). The ref is taken under `refs/` (`refs/pull/12/head`) and
    /// the branch under `refs/heads/`, both must pass `git check-ref-format`, neither may start with `-` or `+`, and the
    /// remote must be a remote name (not a URL or an option). An existing branch is only fast-forwarded (git refuses
    /// anything else, and a branch checked out anywhere). The token goes through the gate like every network command.
    public func fetchRefspec(remote: String, refspec: String) async throws {
        let parts = refspec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let source = parts.first, let branch = parts.last,
              !source.hasPrefix("-"), !source.hasPrefix("+"), !branch.hasPrefix("+"),
              !refspec.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
        else { throw GitOperationError.invalidRefspec(refspec) }
        let sourceRef = source.hasPrefix("refs/") ? source : "refs/\(source)"
        guard !source.isEmpty, await checkRefFormat(sourceRef) else { throw GitOperationError.invalidRefspec(refspec) }
        try await validateRemoteName(remote)
        try await validateBranchName(branch)
        try await lane { ops in
            try await ops.networkExec(
                ["fetch", "--end-of-options", remote, "\(sourceRef):refs/heads/\(branch)"],
                target: .fetch(remotes: [remote]))
        }
    }

    /// Pulls the current branch's upstream. With the token, it is split so that only the fetch carries it: a
    /// hardened `fetch <remote>` (which marks the upstream for merge in FETCH_HEAD, as `pull` does), then, with the
    /// write environment and the repo's hooks as usual, `merge FETCH_HEAD` with the mode's flags (pull's own merge
    /// message), or for a rebase what `pull --rebase` runs: `rebase --onto <fetched> <fork point>`, the fetched
    /// commit being FETCH_HEAD's for-merge one (not `@{upstream}`, which a refspec may not map, as for a
    /// `refs/pull/<n>/head` checkout, or may leave stale) and the fork point `merge-base --fork-point @{upstream}
    /// HEAD` taken before the fetch, else the fetched commit itself. Without the token (an upstream on another
    /// host, a local one, none at all) it is one `git pull`, as before.
    public func pull(_ mode: PullMode) async throws {
        let flags: [String] = switch mode {
        case .fastForward: ["--no-rebase", "--ff", "--no-edit"]
        case .fastForwardOnly: ["--no-rebase", "--ff-only"]
        case .rebase: ["--rebase"]
        }
        try await lane { ops in
            let remote = ops.credential == nil ? nil : try? await ops.upstreamRemote()
            let decision = await ops.tokenDecision(for: remote.map { .fetch(remotes: [$0]) })
            guard decision == .attach, let remote, let credential = ops.credential else {
                try await ops.withheldExec(decision) { try await ops.exec(["pull"] + flags, network: true) }
                return
            }
            // As `pull`, before the fetch moves the tracking ref; nil without one or without a fork point.
            let forkPoint = mode == .rebase ? await ops.forkPoint() : nil
            try await ops.exec(
                ["fetch", "--end-of-options", remote], network: true,
                environment: ops.tokenEnvironment(.fetch, credential))
            let candidates = try await ops.mergeCandidates()
            switch mode {
            case .fastForward: try await ops.exec(["merge", "--ff", "--no-edit", "FETCH_HEAD"])
            case .fastForwardOnly: try await ops.exec(["merge", "--ff-only", "FETCH_HEAD"])
            case .rebase:
                guard candidates.count == 1, let fetched = candidates.first else {
                    throw GitError.other(exit: 1, stderrTail: "Cannot rebase onto multiple branches.")
                }
                try await ops.exec(["rebase", "--onto", fetched, forkPoint ?? fetched])
            }
        }
    }

    /// The object ids the fetch marked for merge in FETCH_HEAD. Fails as `git pull` does when there is none (the
    /// upstream branch was deleted on the remote, or no `branch.<name>.merge`).
    private func mergeCandidates() async throws -> [String] {
        let path = try await runner.run(
            ["rev-parse", "--path-format=absolute", "--git-path", "FETCH_HEAD"], cwd: cwd, env: env).text
        let fetchHead = (try? String(contentsOfFile: path.trimmingCharacters(in: .newlines), encoding: .utf8)) ?? ""
        // `<oid>\t<empty or not-for-merge>\t<description>` per line.
        let candidates = fetchHead.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, fields[1].isEmpty, Self.isObjectID(String(fields[0])) else { return nil }
            return String(fields[0])
        }
        guard candidates.isEmpty else { return candidates }
        throw GitError.other(
            exit: 1, stderrTail: "Your configuration specifies a branch to merge from the remote, but no such ref "
                + "was fetched.")
    }

    /// `merge-base --fork-point @{upstream} HEAD`, as `pull --rebase` computes it; nil when the upstream is not a
    /// tracking ref (git cannot resolve `@{upstream}`) or has no fork point, and `pull` then rebases from the fetched
    /// commit too.
    private func forkPoint() async -> String? {
        let result = try? await runner.run(
            ["merge-base", "--fork-point", "@{upstream}", "HEAD"], cwd: cwd, env: env, allowedExitCodes: [0, 1, 128])
        let text = result?.exitCode == 0 ? result?.text.trimmingCharacters(in: .newlines) : nil
        return text.flatMap { Self.isObjectID($0) ? $0 : nil }
    }

    /// The remote `pull` fetches from: `branch.<current branch>.remote`. Throws on a detached HEAD or without one.
    private func upstreamRemote() async throws -> String {
        let branch = try await runner.run(["symbolic-ref", "--short", "-q", "HEAD"], cwd: cwd, env: env).text
            .trimmingCharacters(in: .newlines)
        return try await runner.run(["config", "--get", "branch.\(branch).remote"], cwd: cwd, env: env).text
            .trimmingCharacters(in: .newlines)
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
        try await push(args + ["--end-of-options", remote, "refs/heads/\(branch):\(target)"], to: remote)
    }

    /// Mirrors every ref to `remote` (`push --mirror`: deletes remote refs missing here). The caller confirms.
    public func pushMirror(to remote: String) async throws {
        try await push(["push", "--mirror", "--end-of-options", remote], to: remote)
    }

    /// One push to `remote` in the lane, through the token gate.
    private func push(_ args: [String], to remote: String) async throws {
        try await lane { ops in try await ops.networkExec(args, target: .push(remote: remote)) }
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
            try await ops.networkExec(
                ["push", "--end-of-options", remote, "refs/remotes/\(remote)/\(name):refs/heads/\(newName)"],
                target: .push(remote: remote))
            try await ops.networkExec(
                ["push", "--end-of-options", remote, ":refs/heads/\(name)"], target: .push(remote: remote))
        }
    }

    public func deleteRemoteBranch(_ name: String, on remote: String) async throws {
        try await push(["push", "--end-of-options", remote, ":refs/heads/\(name)"], to: remote)
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
        try await push(["push", "--end-of-options", remote, "refs/tags/\(name):refs/tags/\(name)"], to: remote)
    }

    public func deleteRemoteTag(_ name: String, on remote: String) async throws {
        try await push(["push", "--end-of-options", remote, ":refs/tags/\(name)"], to: remote)
    }

    // MARK: - Clone and init

    /// Clones `url` into `destination` (which must not exist; its parent must), reporting git's
    /// `--progress` lines (stderr, split on `\r` and `\n`) as they arrive. `env` is
    /// `GitInvocation.cloneEnvironment(url:profile:base:token:runner:)`. Cancelling the task stops git, and so does
    /// `timeout` (1 h by default; nil = no limit, for huge repos).
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
    /// environment of this one command (the interactive rebase's sequence editor); `environment` replaces it (a
    /// token-carrying command).
    @discardableResult
    func exec(
        _ args: [String], stdin: Data? = nil, network: Bool = false, allowedExitCodes: Set<Int32> = [0],
        extraEnv: [String: String] = [:], environment: [String: String]? = nil
    ) async throws -> GitResult {
        try await runner.run(
            args, cwd: cwd, env: (environment ?? (network ? networkEnv : env)).merging(extraEnv) { $1 }, stdin: stdin,
            timeout: network ? networkTimeout : nil, allowedExitCodes: allowedExitCodes)
    }

    // MARK: - Token

    /// Runs one network command (inside the lane). The gate decides first: with `.attach` (every URL `target`
    /// contacts is `https://<profile host>/…` and the repo sets no network key) git gets the token in the hardened
    /// `.network` environment, with no hook at all for a fetch. A push keeps the repo's pre-push hook, run without
    /// the token by a wrapper (`GitInvocation.prePushHooksFolder`), unless it is git-lfs's stub, whose upload needs
    /// it. Anything else runs with `networkEnv` and no token. A nil `target` (git could not list the remotes) is no
    /// token.
    @discardableResult
    func networkExec(_ args: [String], target: GitInvocation.NetworkTarget?) async throws -> GitResult {
        let decision = await tokenDecision(for: target)
        guard decision == .attach, let credential else {
            return try await withheldExec(decision) { try await exec(args, network: true) }
        }
        guard case .push = target else {
            return try await exec(args, network: true, environment: tokenEnvironment(.fetch, credential))
        }
        // The write environment of the credential's profile: where git finds the hook, and what the hook sees.
        let hookEnv = GitInvocation.environment(profile: credential.profile, base: credential.base, access: .write)
        let hooks = try await GitInvocation.prePushHooksFolder(runner: runner, cwd: cwd, env: hookEnv)
        defer { try? FileManager.default.removeItem(at: hooks) }
        return try await exec(
            args, network: true, environment: tokenEnvironment(.push(hooksPath: hooks.path), credential))
    }

    func tokenDecision(for target: GitInvocation.NetworkTarget?) async -> GitInvocation.TokenDecision {
        guard let credential else { return .noToken }
        guard let target else { return .lookupFailed }
        return await GitInvocation.networkToken(
            for: target, profile: credential.profile, token: credential.token, base: credential.base, runner: runner,
            cwd: cwd)
    }

    func tokenEnvironment(_ kind: GitInvocation.NetworkKind, _ credential: NetworkCredential) -> [String: String] {
        GitInvocation.environment(
            profile: credential.profile, base: credential.base, access: .network(kind), token: credential.token)
    }

    /// Runs a network command that did not get the token; when the repo's own network config or its submodule
    /// recursion kept it back and git then could not sign in, throws `NetworkTokenWithheld` so the message can say why.
    func withheldExec<T: Sendable>(_ decision: GitInvocation.TokenDecision, _ body: () async throws -> T)
        async throws -> T
    {
        do {
            return try await body()
        } catch let error as GitError {
            guard case .auth = error else { throw error }
            switch decision {
            case .repoNetworkConfig(let keys): throw NetworkTokenWithheld(reason: .repoNetworkConfig(keys: keys), error: error)
            case .submoduleRecursion(let keys):
                throw NetworkTokenWithheld(reason: .submoduleRecursion(keys: keys), error: error)
            case .attach, .noToken, .otherURL, .lookupFailed: throw error
            }
        }
    }
}
