// Key feature tests for line staging (task 3.2) on a private copy of the `graph` fixture: staging some of a
// file's changed lines puts exactly those lines in the index and unstaging reverses it, line by line; a
// file without a final newline round-trips through stage, unstage and discard; a path with a tab, a quote,
// a space and non-ASCII bytes survives the diff parser and a rebuilt patch header; and a read on a partial
// clone that misses an object throws the typed error the UI turns into a user-initiated fetch.
import Foundation
import HistqCore
import Testing

struct PatchBuilderTests {
    /// The fixture copy, its `graph` repo, the read environment and the write environment for it.
    struct Repo {
        let copy: FixtureCopy
        let repo: URL
        let readEnv: [String: String]
        let writeEnv: [String: String]

        init() async throws {
            copy = try await Fixtures.copy()
            repo = copy.repo("graph")
            readEnv = try await GitInvocation.readEnvironment(profile: nil, base: copy.base, runner: copy.runner, cwd: repo)
            writeEnv = GitInvocation.environment(profile: nil, base: copy.base)
        }

        func unstaged(_ path: String) async throws -> FileDiff {
            try #require(try await DiffReader.unstaged(runner: copy.runner, cwd: repo, env: readEnv, paths: [path]).first)
        }

        func staged(_ path: String) async throws -> FileDiff {
            try #require(try await DiffReader.staged(runner: copy.runner, cwd: repo, env: readEnv, paths: [path]).first)
        }

        func apply(_ file: FileDiff, _ lines: some Sequence<DiffLineID>, _ action: PatchBuilder.Action) async throws {
            let patch = try PatchBuilder.patch(for: file, selecting: Set(lines), action: action)
            try await PatchBuilder.apply(patch, action: action, runner: copy.runner, cwd: repo, env: writeEnv)
        }

        /// The exact bytes of a blob (`:path` is the index).
        func blob(_ object: String) async throws -> Data {
            try await copy.runner.run(["cat-file", "blob", object], cwd: repo, env: copy.base).stdout
        }

        /// The `+`/`-` lines of `git diff [args] -- path`, file headers excluded.
        func changedLines(_ args: [String], _ path: String) async throws -> [String] {
            try await copy.git(["diff"] + args + ["--", path], in: repo).split(separator: "\n").map(String.init)
                .filter { ($0.hasPrefix("+") || $0.hasPrefix("-")) && !$0.hasPrefix("+++ ") && !$0.hasPrefix("--- ") }
        }
    }

    @Test("staging 2 of 4 changed lines leaves exactly those lines in the index, and unstaging reverses it line by line")
    func stageTwoOfFourLinesThenUnstage() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let head = try await fx.blob("HEAD:README.md")
        let oldLine = "It has merges, tags, stashes and a remote."
        let newLine = "It has merges, tags, stashes and a remote (edited)."

        let file = try await fx.unstaged("README.md")
        let changed = file.changedLineIDs
        try #require(changed.count == 4)
        let line = { (id: DiffLineID) in file.hunks[id.hunk].lines[id.line] }
        let removed = try #require(changed.first { line($0).kind == .removed })
        let added = try #require(changed.first { line($0).kind == .added })
        #expect(line(removed).text == oldLine)
        #expect(line(added).text == newLine)

        try await fx.apply(file, [removed, added], .stage)
        #expect(try await fx.changedLines(["--cached"], "README.md") == ["-" + oldLine, "+" + newLine])
        let replaced = String(decoding: head, as: UTF8.self).replacing(oldLine + "\n", with: newLine + "\n")
        #expect(try await fx.blob(":README.md") == Data(replaced.utf8))
        #expect(try await fx.unstaged("README.md").changedLineIDs.count == 2, "the other 2 lines stay unstaged")

        // Unstage the added line alone (reverse: the unselected removal is dropped), then the removal.
        let staged = try await fx.staged("README.md")
        let stagedAdded = try #require(staged.changedLineIDs.first { staged.hunks[$0.hunk].lines[$0.line].kind == .added })
        try await fx.apply(staged, [stagedAdded], .unstage)
        #expect(try await fx.changedLines(["--cached"], "README.md") == ["-" + oldLine])
        let rest = try await fx.staged("README.md")
        try await fx.apply(rest, rest.changedLineIDs, .unstage)
        #expect(try await fx.blob(":README.md") == head)
        #expect(try await fx.changedLines(["--cached"], "README.md").isEmpty)
        #expect(try await fx.unstaged("README.md").changedLineIDs.count == 4, "the working tree is untouched")
    }

    @Test("a file without a final newline round-trips through partial stage, unstage and discard")
    func noFinalNewlineRoundTrips() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let path = "no-newline.txt"
        let worktree = fx.repo.appending(path: path)
        let mixed = Data("first line\nsecond line edited\nlast line without newline".utf8)
        let file = try await fx.unstaged(path)
        let lastLine = try #require(file.hunks.last?.lines.last)
        #expect(lastLine.noNewlineAtEnd && lastLine.kind == .added)

        // The second-line pair: the unselected old last line becomes context and keeps its marker.
        let second = file.changedLineIDs.filter { file.hunks[$0.hunk].lines[$0.line].text.hasPrefix("second") }
        try #require(second.count == 2)
        try await fx.apply(file, second, .stage)
        #expect(try await fx.blob(":\(path)") == mixed)

        let rest = try await fx.unstaged(path)
        try await fx.apply(rest, rest.changedLineIDs, .stage)
        #expect(try await fx.blob(":\(path)") == (try Data(contentsOf: worktree)))

        let staged = try await fx.staged(path)
        let last = staged.changedLineIDs.filter { staged.hunks[$0.hunk].lines[$0.line].text.hasPrefix("last") }
        try #require(last.count == 2)
        try await fx.apply(staged, last, .unstage)
        #expect(try await fx.blob(":\(path)") == mixed)

        let unstaged = try await fx.unstaged(path)
        try await fx.apply(unstaged, unstaged.changedLineIDs, .discard)
        #expect(try Data(contentsOf: worktree) == mixed)
        #expect(try await DiffReader.unstaged(runner: fx.copy.runner, cwd: fx.repo, env: fx.readEnv, paths: [path]).isEmpty)
    }

    @Test("a path with a tab, a quote, a space and non-ASCII bytes round-trips through the diff and a partial patch")
    func unusualPathRoundTrips() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let name = "odd\tna\"me ö.txt"
        let url = fx.repo.appending(path: name)
        let original = (1...20).map { "line \($0)\n" }
        try Data(original.joined().utf8).write(to: url)
        try await fx.copy.git(["add", "--", name], in: fx.repo)
        try await fx.copy.git(["commit", "-q", "-m", "odd name", "--", name], in: fx.repo)
        var edited = original
        edited[17] = "line 18 edited\n"
        edited.insert(contentsOf: ["new a\n", "new b\n"], at: 2)
        try Data(edited.joined().utf8).write(to: url)

        let file = try await fx.unstaged(name)
        #expect(file.path == name)
        try #require(file.hunks.count == 2)
        // One of the two inserted lines (the second hunk's new start shifts by 1) and the whole second hunk.
        let newA = try #require(file.changedLineIDs(inHunk: 0).first)
        try await fx.apply(file, [newA] + file.changedLineIDs(inHunk: 1), .stage)
        var expected = original
        expected[17] = "line 18 edited\n"
        expected.insert("new a\n", at: 2)
        #expect(try await fx.blob(":\(name)") == Data(expected.joined().utf8))

        let staged = try await fx.staged(name)
        #expect(staged.path == name)
        try #require(staged.hunks.count == 2)
        try await fx.apply(staged, staged.changedLineIDs(inHunk: 1), .unstage)
        var unstaged = original
        unstaged.insert("new a\n", at: 2)
        #expect(try await fx.blob(":\(name)") == Data(unstaged.joined().utf8))
    }

    @Test("a read that misses an object of a partial clone throws missingObjects instead of fetching")
    func partialCloneMissingObjectIsTyped() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.copy.git(["config", "uploadpack.allowFilter", "true"], in: fx.repo)
        let clone = fx.copy.folder.appending(path: "partial", directoryHint: .isDirectory)
        try await fx.copy.git(
            ["clone", "-q", "--filter=blob:none", "--no-checkout", "--", "file://\(fx.repo.path)", clone.path],
            in: fx.copy.folder)
        let env = try await GitInvocation.readEnvironment(profile: nil, base: fx.copy.base, runner: fx.copy.runner, cwd: clone)

        await #expect(throws: DiffReadError.self) {
            try await DiffReader.commit("HEAD", runner: fx.copy.runner, cwd: clone, env: env)
        }
        await #expect(throws: DiffReadError.self) {
            try await DiffReader.file(at: "HEAD", path: "README.md", runner: fx.copy.runner, cwd: clone, env: env)
        }
        // Control: the full repo reads the same objects.
        #expect(try await !DiffReader.file(at: "HEAD", path: "README.md", runner: fx.copy.runner, cwd: fx.repo, env: fx.readEnv).isEmpty)
    }
}
