// Key feature tests for the readers (task 2.4) on a private copy of the `graph` fixture: the history the
// graph lays out (merges keep both parents, stash internals never become rows), the ref labels with their
// upstream counts and peeled tags, the working tree status, and the stash and worktree rows.
import Foundation
import HistqCore
import Testing

struct RepoReadTests {
    /// The fixture copy, its `graph` repo and the read environment for it (as every automatic read uses).
    struct Graph {
        let copy: FixtureCopy
        let repo: URL
        let env: [String: String]
        var runner: GitRunner { copy.runner }

        init() async throws {
            let copy = try await Fixtures.copy()
            self.copy = copy
            repo = copy.repo("graph")
            env = try await GitInvocation.readEnvironment(profile: nil, base: copy.base, runner: copy.runner, cwd: repo)
        }

        /// The read environment for another repo of the copy (each folder gets its own filter listing).
        func readEnvironment(for repo: URL) async throws -> [String: String] {
            try await GitInvocation.readEnvironment(profile: nil, base: copy.base, runner: copy.runner, cwd: repo)
        }
    }

    @Test("the log streams every commit in pages, a merge keeps both parents, and stash internals are no rows")
    func logKeepsMergesAndHidesStashInternals() async throws {
        let graph = try await Graph()
        defer { graph.copy.remove() }

        var pages: [[Commit]] = []
        for try await page in LogReader.pages(runner: graph.runner, cwd: graph.repo, env: graph.env, pageSize: 4) {
            pages.append(page)
        }
        let commits = pages.flatMap { $0 }
        let hashes = Set(commits.map(\.hash))
        #expect(pages.count > 1)
        #expect(pages.dropLast().allSatisfy { $0.count == 4 })
        #expect(hashes.count == commits.count, "no commit twice")
        let expected = try await graph.copy.git(
            ["rev-list", "--count", "--exclude=refs/stash", "--all"], in: graph.repo)
        #expect(commits.count == Int(expected))

        let merge = try #require(commits.first { $0.subject == "Merge branch 'develop'" })
        let mergeParents = try await graph.copy.git(["rev-parse", "v1.0^1", "v1.0^2"], in: graph.repo)
        #expect(merge.parents == mergeParents.split(separator: "\n").map(String.init))
        #expect(merge.authorName == "Histq Fixture")
        #expect(merge.authorEmail == "fixture@histq.invalid")

        // The stash's base (main's tip) is a row; the stash commit and its index and untracked commits are not.
        let stashCommits = try await graph.copy.git(
            ["rev-parse", "stash@{0}^1", "stash@{0}", "stash@{0}^2", "stash@{0}^3"], in: graph.repo
        ).split(separator: "\n").map(String.init)
        try #require(stashCommits.count == 4)
        #expect(hashes.contains(stashCommits[0]))
        for hidden in stashCommits.dropFirst() {
            #expect(!hashes.contains(hidden), "stash internal \(hidden) is a log row")
        }
    }

    @Test("refs carry HEAD (branch or detached), upstream ahead/behind counts and the annotated tag's peeled commit")
    func refsCarryTrackingAndPeeledTags() async throws {
        let graph = try await Graph()
        defer { graph.copy.remove() }
        let refs = try await RefReader.read(runner: graph.runner, cwd: graph.repo, env: graph.env)
        let mainTip = try await graph.copy.git(["rev-parse", "main"], in: graph.repo)

        #expect(refs.head == .branch("main", commit: mainTip))
        let branches = Dictionary(uniqueKeysWithValues: refs.localBranches.map { ($0.name, $0) })
        #expect(Set(branches.keys) == ["main", "develop", "feature", "series", "wt"])
        let main = try #require(branches["main"])
        #expect(main.isHead && main.upstream == "origin/main" && main.ahead == 0 && main.behind == 0)
        let develop = try #require(branches["develop"])
        #expect(develop.upstream == "origin/develop" && develop.ahead == 1 && develop.behind == 0)
        let feature = try #require(branches["feature"])
        #expect(feature.upstream == "origin/feature" && feature.ahead == 0 && feature.behind == 1)
        #expect(branches["series"]?.upstream == nil)

        #expect(Set(refs.remoteBranches.map(\.name)) == ["origin/main", "origin/develop", "origin/feature"])
        #expect(refs.remoteBranches.allSatisfy { $0.remote == "origin" })

        let tags = Dictionary(uniqueKeysWithValues: refs.tags.map { ($0.name, $0) })
        let annotated = try #require(tags["v1.0"])
        let tagObject = try await graph.copy.git(["rev-parse", "refs/tags/v1.0"], in: graph.repo)
        let tagCommit = try await graph.copy.git(["rev-parse", "v1.0^{commit}"], in: graph.repo)
        #expect(annotated.isAnnotated && annotated.target == tagObject && annotated.commit == tagCommit)
        #expect(tagObject != tagCommit)
        let lightweight = try #require(tags["v0.1"])
        let lightCommit = try await graph.copy.git(["rev-parse", "v0.1"], in: graph.repo)
        #expect(!lightweight.isAnnotated && lightweight.target == lightCommit && lightweight.commit == lightCommit)

        // A rebase stopped on a conflict leaves HEAD detached.
        let rebasing = graph.copy.repo("conflict-rebase")
        let rebasingRefs = try await RefReader.read(
            runner: graph.runner, cwd: rebasing, env: try await graph.readEnvironment(for: rebasing))
        let rebasingHead = try await graph.copy.git(["rev-parse", "HEAD"], in: rebasing)
        #expect(rebasingRefs.head == .detached(commit: rebasingHead))
        #expect(!rebasingRefs.localBranches.contains { $0.isHead })
    }

    @Test("status covers staged, unstaged, untracked, the staged rename, a file named -rf and conflicts")
    func statusCoversEveryKind() async throws {
        let graph = try await Graph()
        defer { graph.copy.remove() }
        let status = try await StatusReader.read(runner: graph.runner, cwd: graph.repo, env: graph.env)

        #expect(status.branch.name == "main")
        #expect(status.branch.upstream == "origin/main" && status.branch.ahead == 0 && status.branch.behind == 0)
        let byPath = Dictionary(uniqueKeysWithValues: status.entries.map { ($0.path, $0) })

        let app = try #require(byPath["src/app.swift"])
        #expect(app.kind == .ordinary && app.index == .modified && app.worktree == .modified)
        #expect(byPath["staged.txt"]?.index == .added)
        #expect(byPath["README.md"]?.worktree == .modified && byPath["README.md"]?.index == .unmodified)
        let rename = try #require(byPath["new-name.txt"])
        #expect(rename.kind == .renamed && rename.originalPath == "old-name.txt" && rename.similarity == 100)
        #expect(rename.index == .renamed)
        #expect(byPath["-rf"]?.kind == .untracked)
        #expect(byPath["untracked.txt"]?.kind == .untracked)

        #expect(Set(status.staged.map(\.path)) == ["src/app.swift", "staged.txt", "new-name.txt"])
        #expect(Set(status.unstaged.map(\.path)) == ["src/app.swift", "README.md", "no-newline.txt", "image.bin"])
        #expect(Set(status.untracked.map(\.path)) == ["-rf", "untracked.txt"])
        #expect(status.conflicted.isEmpty)

        // A merge stopped on conflicts: both-modified, modified/deleted and add/add.
        let conflict = graph.copy.repo("conflict")
        let merging = try await StatusReader.read(
            runner: graph.runner, cwd: conflict, env: try await graph.readEnvironment(for: conflict))
        let codes = Dictionary(uniqueKeysWithValues: merging.conflicted.map {
            ($0.path, "\($0.index.rawValue)\($0.worktree.rawValue)")
        })
        #expect(codes == ["long.txt": "UU", "gone.txt": "UD", "add.txt": "AA"])
        #expect(merging.entries.count == 3 && merging.staged.isEmpty && merging.unstaged.isEmpty)

        // The same conflicts mid-rebase: HEAD is detached.
        let rebasing = graph.copy.repo("conflict-rebase")
        let rebaseStatus = try await StatusReader.read(
            runner: graph.runner, cwd: rebasing, env: try await graph.readEnvironment(for: rebasing))
        #expect(rebaseStatus.branch.name == nil && rebaseStatus.branch.commit != nil)
        #expect(rebaseStatus.conflicted.count == 3)
    }

    @Test("stashes come with their base commit and the linked worktree is found")
    func stashBasesAndWorktrees() async throws {
        let graph = try await Graph()
        defer { graph.copy.remove() }
        let stashes = try await StashWorktreeReader.stashes(runner: graph.runner, cwd: graph.repo, env: graph.env)
        try #require(stashes.count == 2)
        for stash in stashes {
            let expected = try await graph.copy.git(
                ["rev-parse", stash.selector, "\(stash.selector)^1"], in: graph.repo)
            #expect([stash.hash, stash.base].joined(separator: "\n") == expected)
        }
        #expect(stashes[0].message.hasSuffix("scratch with untracked") && stashes[0].otherParents.count == 2)
        #expect(stashes[1].message.hasSuffix("guide tweaks") && stashes[1].otherParents.count == 1)

        let worktrees = try await StashWorktreeReader.worktrees(runner: graph.runner, cwd: graph.repo, env: graph.env)
        try #require(worktrees.count == 2)
        let resolved = { (path: String) in URL(filePath: path).resolvingSymlinksInPath().path }
        #expect(worktrees[0].isMain && resolved(worktrees[0].path) == resolved(graph.repo.path))
        #expect(worktrees[0].branch == "refs/heads/main")
        let linked = worktrees[1]
        let wtTip = try await graph.copy.git(["rev-parse", "wt"], in: graph.repo)
        #expect(!linked.isMain && resolved(linked.path) == resolved(graph.copy.repo("graph-wt").path))
        #expect(linked.branch == "refs/heads/wt" && linked.head == wtTip && !linked.isDetached)
    }
}
