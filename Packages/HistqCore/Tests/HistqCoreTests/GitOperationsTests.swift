// Key feature and security tests for the write operations and RepoState (task 3.4), each on a private
// fixture copy with the hermetic environment: a conflicting merge gives a merging state and abort restores
// HEAD; a merge is reverted with `-m 1`; option-looking names and paths never become options; a
// force-with-lease push is refused once the origin moved (and accepted with the right sha); the rebase
// fixture's labels are swapped (A = upstream, B = the replayed commit); remotes round-trip.
import Foundation
import HistqCore
import Testing

struct GitOperationsTests {
    /// A fixture copy, the operations on one of its repos and the read environment for it.
    struct Repo {
        let copy: FixtureCopy
        let repo: URL
        let ops: GitOperations

        init(_ name: String) async throws {
            copy = try await Fixtures.copy()
            repo = copy.repo(name)
            ops = GitOperations(
                runner: copy.runner, cwd: repo, env: GitInvocation.environment(profile: nil, base: copy.base),
                networkTimeout: .seconds(30))
        }

        @discardableResult
        func git(_ args: [String]) async throws -> String { try await copy.git(args, in: repo) }

        func state() async throws -> RepoState {
            let env = try await GitInvocation.readEnvironment(profile: nil, base: copy.base, runner: copy.runner, cwd: repo)
            return try await RepoState.read(runner: copy.runner, cwd: repo, env: env)
        }

        func lines(_ args: [String]) async throws -> [String] {
            try await git(args).split(separator: "\n").map(String.init)
        }
    }

    @Test("a conflicting merge gives a merging state with long.txt conflicted, and abort restores HEAD")
    func mergeConflictThenAbort() async throws {
        let fx = try await Repo("conflict")
        defer { fx.copy.remove() }
        // The fixture is stopped in this same merge: abort it first, then merge again.
        try await fx.ops.abortOperation(.merge)
        #expect(try await fx.state().operation == .none)
        let head = try await fx.git(["rev-parse", "HEAD"])

        await #expect {
            try await fx.ops.merge("feature")
        } throws: { error in
            if case GitError.conflict = error { true } else { false }
        }
        let merging = try await fx.state()
        #expect(merging.operation == .merge)
        #expect(merging.conflictedPaths.contains("long.txt"))
        #expect(Set(merging.conflictedPaths) == ["add.txt", "gone.txt", "long.txt"])
        #expect(merging.labels == ConflictLabels(a: "main", b: "feature"))

        try await fx.ops.abortOperation(.merge)
        let after = try await fx.state()
        #expect(after.operation == .none)
        #expect(after.conflictedPaths.isEmpty)
        #expect(try await fx.git(["rev-parse", "HEAD"]) == head)
        #expect(try await fx.git(["status", "--porcelain"]).isEmpty)
    }

    @Test("reverting a merge with -m 1 undoes the merged branch's changes on top of HEAD")
    func revertMergeWithMainline() async throws {
        let fx = try await Repo("graph")
        defer { fx.copy.remove() }
        // The fixture's index is dirty (staged and untracked WIP): revert refuses until it is stashed.
        try await fx.ops.stashPush(message: "before revert")
        #expect(try await fx.git(["status", "--porcelain"]).isEmpty)
        let head = try await fx.git(["rev-parse", "HEAD"])
        let merge = try await fx.git(["rev-parse", "v1.0^{commit}"])
        #expect(try await fx.lines(["rev-list", "--parents", "-n", "1", merge]).first?.split(separator: " ").count == 3)

        try await fx.ops.revert(merge, mainline: 1)
        #expect(try await fx.git(["rev-parse", "HEAD^"]) == head)
        #expect(try await fx.git(["log", "-1", "--format=%s"]) == "Revert \"Merge branch 'develop'\"")
        // The develop side (config, feature, changelog) is gone; main's later VERSION commit stays.
        let merged = ["src/config.swift", "src/feature.swift", "CHANGELOG.md"]
        _ = try await fx.copy.runner.run(
            ["diff", "--quiet", "\(merge)^1", "HEAD", "--"] + merged, cwd: fx.repo, env: fx.copy.base)
        #expect(try await fx.git(["show", "HEAD:VERSION"]) == "1.0.1")
    }

    @Test("names and revisions that look like options are rejected or never parsed as options")
    func optionLookingNamesAreRejected() async throws {
        let fx = try await Repo("graph")
        defer { fx.copy.remove() }
        let branchesBefore = try await fx.git(["for-each-ref", "--format=%(refname)"])

        await #expect(throws: GitOperationError.invalidBranchName("-x")) {
            try await fx.ops.createBranch("-x", from: "HEAD")
        }
        await #expect(throws: GitOperationError.invalidBranchName("-x")) {
            try await fx.ops.renameBranch("develop", to: "-x")
        }
        await #expect(throws: GitOperationError.invalidTagName("-x")) {
            try await fx.ops.createTag("-x", at: "HEAD")
        }
        await #expect(throws: GitOperationError.invalidBranchName("a..b")) {
            try await fx.ops.createBranch("a..b", from: "HEAD")
        }
        // A revision is never an option: `--orphan=evil` is an unknown revision, not a new branch.
        await #expect(throws: GitError.self) {
            try await fx.ops.checkout(commit: "--orphan=evil")
        }
        #expect(try await fx.git(["for-each-ref", "--format=%(refname)"]) == branchesBefore)
        #expect(try await fx.git(["rev-parse", "--abbrev-ref", "HEAD"]) == "main")
    }

    @Test("the file named -rf stages and unstages as a path, nothing else changes")
    func dashFileStagesAsPath() async throws {
        let fx = try await Repo("graph")
        defer { fx.copy.remove() }
        let stagedBefore = try await fx.lines(["diff", "--cached", "--name-only"])
        #expect(!stagedBefore.contains("-rf"))

        try await fx.ops.stage(["-rf"])
        let staged = try await fx.lines(["diff", "--cached", "--name-only"])
        #expect(Set(staged) == Set(stagedBefore + ["-rf"]))
        #expect(try await fx.lines(["ls-files", "--others", "--exclude-standard"]) == ["untracked.txt"])
        #expect(FileManager.default.fileExists(atPath: fx.repo.appending(path: "-rf").path))

        try await fx.ops.unstage(["-rf"])
        #expect(try await fx.lines(["diff", "--cached", "--name-only"]) == stagedBefore)
        await #expect(throws: GitOperationError.noPaths) { try await fx.ops.stage([]) }
    }

    @Test("force-with-lease is refused after the origin moved, and accepted with the origin's sha")
    func forceWithLeaseRefusesAfterOriginMoved() async throws {
        let fx = try await Repo("graph")
        defer { fx.copy.remove() }
        let origin = fx.copy.repo("graph-origin.git")
        let expected = try await fx.git(["rev-parse", "origin/main"])
        #expect(try await fx.git(["rev-parse", "main"]) == expected)

        // Someone else pushes to origin's main (origin/main here is not fetched, so it is stale).
        let moved = try await fx.git(["commit-tree", "-p", "main", "-m", "pushed elsewhere", "main^{tree}"])
        try await fx.git(["push", "-q", "origin", "\(moved):refs/heads/main"])
        // Local main is rewritten.
        let rewritten = try await fx.git(["commit-tree", "-p", "main", "-m", "rewritten", "main^{tree}"])
        try await fx.git(["update-ref", "refs/heads/main", rewritten])

        await #expect {
            try await fx.ops.push(branch: "main", to: "origin", forceWithLease: expected)
        } throws: { error in
            if case GitError.nonFastForward = error { true } else { false }
        }
        #expect(try await fx.copy.git(["rev-parse", "refs/heads/main"], in: origin) == moved)

        try await fx.ops.push(branch: "main", to: "origin", forceWithLease: moved)
        #expect(try await fx.copy.git(["rev-parse", "refs/heads/main"], in: origin) == rewritten)
        await #expect(throws: GitOperationError.invalidObjectID("main")) {
            try await fx.ops.push(branch: "main", to: "origin", forceWithLease: "main")
        }
    }

    @Test("the rebase fixture swaps the labels: A = the upstream, B = the commit being replayed")
    func rebaseSwapsLabels() async throws {
        let fx = try await Repo("conflict-rebase")
        defer { fx.copy.remove() }
        let state = try await fx.state()
        #expect(state.operation == .rebase)
        #expect(Set(state.conflictedPaths) == ["add.txt", "gone.txt", "long.txt"])
        let replayed = try await fx.git(["log", "-1", "--format=%h %s", "feature"])
        #expect(replayed.hasSuffix(" Feature changes"))
        #expect(state.labels == ConflictLabels(a: "main", b: replayed))
        // The labels match the stages: :2 holds main's long.txt, :3 the feature commit's.
        #expect(try await fx.git(["show", ":2:long.txt"]) == (try await fx.git(["show", "main:long.txt"])))
        #expect(try await fx.git(["show", ":3:long.txt"]) == (try await fx.git(["show", "feature:long.txt"])))

        try await fx.ops.abortOperation(.rebase)
        #expect(try await fx.state().operation == .none)
        #expect(try await fx.git(["rev-parse", "--abbrev-ref", "HEAD"]) == "feature")
    }

    @Test("remote add, rename and remove round-trip; bad remote names and URLs are rejected")
    func remoteRoundTrip() async throws {
        let fx = try await Repo("graph")
        defer { fx.copy.remove() }
        let url = "../graph-origin.git"

        try await fx.ops.addRemote("backup", url: url)
        #expect(try await fx.lines(["remote"]) == ["backup", "origin"])
        try await fx.ops.renameRemote("backup", to: "mirror.2")
        #expect(try await fx.lines(["remote"]) == ["mirror.2", "origin"])
        #expect(try await fx.git(["config", "remote.mirror.2.url"]) == url)
        try await fx.ops.setRemoteURL("mirror.2", url: "../elsewhere.git")
        #expect(try await fx.git(["config", "remote.mirror.2.url"]) == "../elsewhere.git")
        try await fx.ops.removeRemote("mirror.2")
        #expect(try await fx.lines(["remote"]) == ["origin"])

        for name in ["-x", "bad name", "a/b", "..", "x.lock"] {
            await #expect(throws: GitOperationError.invalidRemoteName(name)) {
                try await fx.ops.addRemote(name, url: url)
            }
        }
        await #expect(throws: GitOperationError.invalidRemoteURL("-oProxyCommand=touch /tmp/x")) {
            try await fx.ops.addRemote("evil", url: "-oProxyCommand=touch /tmp/x")
        }
        #expect(try await fx.lines(["remote"]) == ["origin"])
    }

    @Test("fast-forward moves a behind branch, refuses a diverged one, ff-merges HEAD's, never another worktree's")
    func fastForward() async throws {
        let fx = try await Repo("graph")
        defer { fx.copy.remove() }

        // feature is behind origin/feature by 1: it moves there, HEAD stays on main.
        try await fx.ops.fastForward("feature", to: "refs/remotes/origin/feature")
        #expect(try await fx.git(["rev-parse", "feature"]) == (try await fx.git(["rev-parse", "origin/feature"])))
        #expect(try await fx.git(["rev-parse", "--abbrev-ref", "HEAD"]) == "main")

        // develop is ahead of origin/develop: not a fast-forward.
        let develop = try await fx.git(["rev-parse", "develop"])
        await #expect {
            try await fx.ops.fastForward("develop", to: "refs/remotes/origin/develop")
        } throws: { error in
            if case GitError.nonFastForward = error { true } else { false }
        }
        #expect(try await fx.git(["rev-parse", "develop"]) == develop)

        // wt is checked out in graph-wt: refused, unchanged.
        let wt = try await fx.git(["rev-parse", "wt"])
        let next = try await fx.git(["commit-tree", "-p", "wt", "-m", "next", "wt^{tree}"])
        try await fx.git(["update-ref", "refs/heads/wt-next", next])
        await #expect(throws: (any Error).self) { try await fx.ops.fastForward("wt", to: "refs/heads/wt-next") }
        #expect(try await fx.git(["rev-parse", "wt"]) == wt)

        // The checked-out branch: merge --ff-only, the working tree follows.
        try await fx.git(["stash", "push", "-q", "-u"])
        let main = try await fx.git(["rev-parse", "main"])
        try await fx.git(["reset", "-q", "--hard", "main~1"])
        try await fx.ops.fastForward("main", to: "refs/remotes/origin/main")
        #expect(try await fx.git(["rev-parse", "main"]) == main)
        #expect(try await fx.git(["status", "--porcelain"]).isEmpty)

        await #expect(throws: GitOperationError.invalidBranchName("-x")) {
            try await fx.ops.fastForward("-x", to: "refs/heads/main")
        }
        await #expect(throws: GitOperationError.invalidBranchName("+refs/heads/main")) {
            try await fx.ops.fastForward("feature", to: "+refs/heads/main")
        }
    }
}
