// Key feature tests for the undo journal (task 9.1), each on a private copy of the dirty `graph` fixture (staged,
// unstaged, renamed, binary and untracked changes, an untracked file named `-rf`): undo of a commit, a discard and
// a branch delete puts the whole state back (HEAD, branch, index, files), a discard made from a subfolder too; redo
// replays a commit; files staged between two commits do not block undoing both; undo refuses once a commit was made
// outside Histq, and refuses a tampered journal (a path into `.git`, an upstream that is no remote name) unchanged.
import Foundation
import HistqCore
import Testing

struct UndoJournalTests {
    /// A fixture copy and journaled operations on its `graph` repo; the journal file lives outside the repo.
    struct Repo {
        let copy: FixtureCopy
        let repo: URL
        let journal: UndoJournal
        let ops: GitOperations

        /// `folder`: the operations run in this subfolder of the repo (as when a subfolder was opened).
        init(folder: String? = nil) async throws {
            copy = try await Fixtures.copy()
            let repo = copy.repo("graph")
            self.repo = repo
            journal = UndoJournal(file: copy.folder.appending(path: "state/undo/graph.json"))
            ops = GitOperations(
                runner: copy.runner, cwd: folder.map { repo.appending(path: $0, directoryHint: .isDirectory) } ?? repo,
                env: GitInvocation.environment(profile: nil, base: copy.base), networkTimeout: .seconds(30),
                journal: journal)
        }

        /// Edits the journal file as an attacker could: every string value `old` becomes `new`.
        func tamper(_ old: String, with new: String) throws {
            func swap(_ value: Any) -> Any {
                switch value {
                case let text as String: text == old ? new : text
                case let array as [Any]: array.map(swap)
                case let object as [String: Any]: object.mapValues(swap)
                default: value
                }
            }
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: journal.file))
            try JSONSerialization.data(withJSONObject: swap(json)).write(to: journal.file)
        }

        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(repo.appending(path: path).path, &info) == 0
        }

        @discardableResult
        func git(_ args: [String]) async throws -> String { try await copy.git(args, in: repo) }

        /// HEAD, the branch it is on, the status (staged, unstaged and untracked) and both diffs: equal states
        /// mean the index and the files came back too, not just the commit.
        func state() async throws -> [String] {
            [
                try await git(["rev-parse", "HEAD"]),
                try await git(["symbolic-ref", "-q", "HEAD"]),
                try await git(["status", "--porcelain"]),
                try await git(["diff", "--cached", "--no-ext-diff", "--binary"]),
                try await git(["diff", "--no-ext-diff", "--binary"]),
            ]
        }

        func bytes(_ path: String) throws -> Data { try Data(contentsOf: repo.appending(path: path)) }
    }

    @Test("undo of a commit moves the branch back and the committed changes are staged again")
    func undoCommit() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let before = try await fx.state()

        try await fx.ops.commit(message: "Commit to undo")
        #expect(try await fx.git(["log", "-1", "--format=%s"]) == "Commit to undo")
        #expect(try fx.journal.load().nextUndo?.kind == .commit)

        let undone = try await fx.ops.undo()
        #expect(undone.kind == .commit)
        #expect(try await fx.state() == before)
        #expect(try fx.journal.load().nextRedo?.id == undone.id)
    }

    @Test("undo of a discard of everything brings back the tracked and untracked files and the index")
    func undoDiscard() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let before = try await fx.state()
        let paths = ["README.md", "src/app.swift", "image.bin", "untracked.txt", "-rf"]
        let contents = try paths.map(fx.bytes)

        try await fx.ops.discardAll(includingUntracked: true)
        #expect(try await fx.git(["status", "--porcelain"]).isEmpty)

        try await fx.ops.undo()
        #expect(try await fx.state() == before)
        #expect(try paths.map(fx.bytes) == contents)
    }

    @Test("undo of a discard of everything made from a subfolder brings back the changes outside it too")
    func undoDiscardFromSubfolder() async throws {
        let fx = try await Repo(folder: "src")
        defer { fx.copy.remove() }
        try Data("untracked in src\n".utf8).write(to: fx.repo.appending(path: "src/new.txt"))
        let before = try await fx.state()
        let paths = ["README.md", "no-newline.txt", "image.bin", "src/app.swift", "src/new.txt", "untracked.txt", "-rf"]
        let contents = try paths.map(fx.bytes)

        try await fx.ops.discardAll(includingUntracked: true)
        // `reset --hard` reset the whole worktree, `clean` only the subfolder.
        #expect(try await fx.git(["status", "--porcelain"]).split(separator: "\n").sorted() == ["?? -rf", "?? untracked.txt"])

        try await fx.ops.undo()
        #expect(try await fx.state() == before)
        #expect(try paths.map(fx.bytes) == contents)
    }

    @Test("undo of a discard of one file made from a subfolder brings that file back")
    func undoPartialDiscardFromSubfolder() async throws {
        let fx = try await Repo(folder: "src")
        defer { fx.copy.remove() }
        let before = try await fx.state()
        let readme = try fx.bytes("README.md")
        let app = try fx.bytes("src/app.swift")

        try await fx.ops.discard(["app.swift"])
        #expect(try fx.bytes("src/app.swift") != app)
        #expect(try fx.bytes("README.md") == readme)

        try await fx.ops.undo()
        #expect(try await fx.state() == before)
        #expect(try fx.bytes("src/app.swift") == app)
    }

    @Test("undo refuses a tampered journal whose untracked file would land in a .git folder, writing nothing",
          arguments: [".GIT/hooks/x", "sub/.git/hooks/x"])
    func undoRefusesGitFolderPath(_ path: String) async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        // A discard that also moved the index: a refusal after `read-tree` would show in `state()`.
        try await fx.ops.discardAll(includingUntracked: true)
        try fx.tamper("untracked.txt", with: path)
        let after = try await fx.state()

        await #expect(throws: UndoError.unsafePath(path)) { try await fx.ops.undo() }
        #expect(try await fx.state() == after)
        #expect(!fx.exists(".git/hooks/x") && !fx.exists("sub") && !fx.exists("untracked.txt"))
        #expect(try fx.journal.load().nextUndo != nil)
    }

    @Test("undo refuses a tampered journal whose branch upstream is not a remote name, writing nothing")
    func undoRefusesBadUpstreamRemote() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.ops.deleteBranch("feature", force: true)
        try fx.tamper("origin", with: "ext::sh -c touch% pwned")

        await #expect(throws: UndoError.unreadableJournal) { try await fx.ops.undo() }
        #expect(try await fx.git(["branch", "--list", "feature"]).isEmpty)
        #expect((try? await fx.git(["config", "--get", "branch.feature.remote"])) == nil)
        #expect(try fx.journal.load().nextUndo != nil)
    }

    @Test("undo of a branch delete recreates the branch at its commit with its upstream")
    func undoBranchDelete() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let commit = try await fx.git(["rev-parse", "refs/heads/feature"])
        let upstream = try await fx.git(["rev-parse", "--abbrev-ref", "feature@{upstream}"])

        try await fx.ops.deleteBranch("feature", force: true)
        #expect(try await fx.git(["branch", "--list", "feature"]).isEmpty)

        try await fx.ops.undo()
        #expect(try await fx.git(["rev-parse", "refs/heads/feature"]) == commit)
        #expect(try await fx.git(["rev-parse", "--abbrev-ref", "feature@{upstream}"]) == upstream)
    }

    @Test("redo after undoing a commit puts the same commit back with the same state")
    func redoCommit() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.ops.commit(message: "Commit to redo")
        let committed = try await fx.state()

        try await fx.ops.undo()
        #expect(try await fx.state() != committed)
        let redone = try await fx.ops.redo()
        #expect(redone.kind == .commit)
        #expect(try await fx.state() == committed)
        #expect(try fx.journal.load().nextRedo == nil)
    }

    @Test("files staged between two commits do not block undoing both; they stay staged")
    func undoCommitsAcrossStaging() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let head = try await fx.git(["rev-parse", "HEAD"])
        let stagedBefore = try await fx.git(["diff", "--cached", "--name-only"])
        #expect(!stagedBefore.contains("README.md"))

        try await fx.ops.commit(message: "First commit")
        // Not journaled: the index moves on after the first entry was recorded.
        try await fx.ops.stage(["README.md"])
        try await fx.ops.commit(message: "Second commit")

        #expect(try await fx.ops.undo().title == "Commit \"Second commit\"")
        #expect(try await fx.ops.undo().title == "Commit \"First commit\"")
        #expect(try await fx.git(["rev-parse", "HEAD"]) == head)
        let staged = try await fx.git(["diff", "--cached", "--name-only"]).split(separator: "\n").map(String.init)
        #expect(Set(staged) == Set(stagedBefore.split(separator: "\n").map(String.init) + ["README.md"]))
    }

    @Test("undo refuses and changes nothing after a commit made outside Histq")
    func undoRefusesAfterOutsideCommit() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.ops.commit(message: "Journaled commit")
        try await fx.git(["commit", "--allow-empty", "-q", "-m", "Terminal commit"])
        let outside = try await fx.state()

        await #expect(throws: UndoError.repositoryChanged) { try await fx.ops.undo() }
        #expect(try await fx.state() == outside)
        #expect(try fx.journal.load().nextUndo != nil)
    }
}
