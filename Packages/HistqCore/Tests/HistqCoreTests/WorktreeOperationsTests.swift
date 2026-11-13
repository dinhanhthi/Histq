// Key feature and security tests for the worktree operations (task 9.4), on private fixture copies of `graph` (its
// linked worktree `graph-wt` is on `wt` with an unstaged CHANGELOG.md edit): a worktree added from a branch checks
// that branch out (a short name, never detached), from a commit it is detached, an option-looking folder name stays a
// folder; remove refuses the main worktree, the caller's own and a dirty one unless forced; prune drops a worktree
// whose folder is gone.
import Foundation
import HistqCore
import Testing

struct WorktreeOperationsTests {
    struct Repo {
        let copy: FixtureCopy
        let repo: URL
        let ops: GitOperations

        init() async throws {
            copy = try await Fixtures.copy()
            repo = copy.repo("graph")
            ops = GitOperations(runner: copy.runner, cwd: repo, env: GitInvocation.environment(profile: nil, base: copy.base))
        }

        func worktrees() async throws -> [Worktree] {
            let env = try await GitInvocation.readEnvironment(profile: nil, base: copy.base, runner: copy.runner, cwd: repo)
            return try await StashWorktreeReader.worktrees(runner: copy.runner, cwd: repo, env: env)
        }

        /// The listed path of the worktree at `url` (git gives real paths).
        func listed(_ url: URL) async throws -> Worktree? {
            let real = url.resolvingSymlinksInPath().path
            return try await worktrees().first { URL(filePath: $0.path).resolvingSymlinksInPath().path == real }
        }
    }

    @Test("a worktree from a branch checks it out, from a commit it is detached, a leading-dash folder stays a folder")
    func addWorktrees() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }

        let fromBranch = fx.copy.root.appending(path: "-wt series")
        try await fx.ops.addWorktree(at: fromBranch.path, from: .branch("series"))
        let series = try #require(try await fx.listed(fromBranch))
        #expect(series.branch == "refs/heads/series" && !series.isDetached)

        let commit = try await fx.copy.git(["rev-parse", "develop"], in: fx.repo)
        let detached = fx.copy.root.appending(path: "wt-detached")
        try await fx.ops.addWorktree(at: detached.path, from: .commit(commit))
        let entry = try #require(try await fx.listed(detached))
        #expect(entry.isDetached && entry.head == commit)

        let newBranch = fx.copy.root.appending(path: "wt-new")
        try await fx.ops.addWorktree(at: newBranch.path, from: .commit(commit), newBranch: "topic")
        #expect(try await fx.listed(newBranch)?.branch == "refs/heads/topic")

        // A branch checked out elsewhere, a name that is not a local branch, and a folder that exists are refused.
        await #expect(throws: (any Error).self) {
            try await fx.ops.addWorktree(at: fx.copy.root.appending(path: "again").path, from: .branch("wt"))
        }
        await #expect(throws: GitOperationError.invalidBranchName("origin/main")) {
            try await fx.ops.addWorktree(at: fx.copy.root.appending(path: "remote").path, from: .branch("origin/main"))
        }
        await #expect(throws: GitOperationError.invalidWorktreePath(detached.path)) {
            try await fx.ops.addWorktree(at: detached.path, from: .branch("feature"))
        }
        #expect(try await fx.worktrees().count == 5)
    }

    @Test("worktree arguments end options before the path and the revision, and refuse injected values")
    func addArguments() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let path = parent + "/histq-wt-args-\(UUID().uuidString)"
        #expect(try GitOperations.addWorktreeArguments(path: path, source: .branch("develop"), newBranch: nil)
            == ["worktree", "add", "--end-of-options", path, "develop"])
        #expect(try GitOperations.addWorktreeArguments(path: path, source: .commit("abc1234"), newBranch: nil)
            == ["worktree", "add", "--detach", "--end-of-options", path, "abc1234"])
        #expect(try GitOperations.addWorktreeArguments(path: path, source: .commit("abc1234"), newBranch: "x")
            == ["worktree", "add", "-b", "x", "--end-of-options", path, "abc1234"])
        #expect(GitOperations.removeWorktreeArguments(path: path, force: true)
            == ["worktree", "remove", "--force", "--end-of-options", path])

        #expect(throws: GitOperationError.invalidBranchName("--force")) {
            try GitOperations.addWorktreeArguments(path: path, source: .commit("abc1234"), newBranch: "--force")
        }
        #expect(throws: GitOperationError.invalidObjectID("HEAD~1")) {
            try GitOperations.addWorktreeArguments(path: path, source: .commit("HEAD~1"), newBranch: nil)
        }
        for bad in ["relative/wt", parent + "/a/../wt", parent + "/wt\nx", parent + "/missing-\(UUID())/wt", "/"] {
            #expect(throws: GitOperationError.invalidWorktreePath(bad)) {
                try GitOperations.addWorktreeArguments(path: bad, source: .branch("develop"), newBranch: nil)
            }
        }
    }

    @Test("remove refuses the main and the current worktree, needs force for a dirty one; prune drops a gone one")
    func removeAndPrune() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let worktrees = try await fx.worktrees()
        let main = try #require(worktrees.first { $0.isMain })
        let linked = try #require(worktrees.first { !$0.isMain })

        await #expect(throws: GitOperationError.mainWorktree(main.path)) { try await fx.ops.removeWorktree(main.path) }
        let inLinked = GitOperations(
            runner: fx.copy.runner, cwd: fx.copy.repo("graph-wt"),
            env: GitInvocation.environment(profile: nil, base: fx.copy.base))
        await #expect(throws: GitOperationError.currentWorktree(linked.path)) {
            try await inLinked.removeWorktree(linked.path)
        }
        await #expect(throws: GitOperationError.notAWorktree("/tmp")) { try await fx.ops.removeWorktree("/tmp") }

        // graph-wt has an unstaged edit: git refuses without force, and the folder stays.
        await #expect(throws: GitError.self) { try await fx.ops.removeWorktree(linked.path) }
        #expect(FileManager.default.fileExists(atPath: linked.path))
        try await fx.ops.removeWorktree(linked.path, force: true)
        #expect(!FileManager.default.fileExists(atPath: linked.path))
        #expect(try await fx.worktrees().count == 1)

        let gone = fx.copy.root.appending(path: "wt-gone")
        try await fx.ops.addWorktree(at: gone.path, from: .branch("feature"))
        try FileManager.default.removeItem(at: gone)
        #expect(try await fx.worktrees().last?.isPrunable == true)
        try await fx.ops.pruneWorktrees()
        #expect(try await fx.worktrees().count == 1)
    }
}
