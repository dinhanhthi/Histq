// Key feature tests for GraphLayout (task 3.1): a merge's second parent opens a lane that is freed after
// the join and reused later, pages lay out like one batch, the `graph` fixture stays narrow with its
// first-parent chain in one color and its stashes hanging from their bases, and (only with
// HISTQ_BIG_FIXTURE) 50k commits parse and lay out in under 2 s.
import Foundation
import HistqCore
import Testing

@Suite(.serialized)
struct GraphLayoutTests {
    @Test("a merge's second parent opens a lane that is freed at the fork and reused, page by page")
    func secondParentLaneIsFreedAndReused() {
        // M2 merges T2; M merges S; S and A fork from F. Children before parents, as --topo-order gives.
        let commits = [
            commit("m2", ["m", "t2"]), commit("t2", ["m"]), commit("m", ["a", "s"]), commit("s", ["f"]),
            commit("a", ["f"]), commit("f", ["r"]), commit("r", []),
        ]
        var layout = GraphLayout()
        let rows = layout.append(commits)

        #expect(rows.map(\.lane) == [0, 1, 0, 1, 0, 0, 0])
        #expect(rows.map(\.width) == [2, 2, 2, 2, 2, 2, 1])
        let merge = rows[2]
        #expect(!merge.top.contains { $0.from == 1 && $0.to == 1 }, "T2's line ended at M: slot 1 is free")
        #expect(merge.bottom.contains(GraphSegment(shape: .bendOut, from: 0, to: 1, color: rows[3].color, isDashed: false)),
                "M's second parent reopens slot 1, in S's color")
        #expect(rows[5].top.contains { $0.shape == .bendIn && $0.from == 1 && $0.to == 0 }, "S's lane joins at F")
        #expect(rows[5].bottom.map(\.from) == [0], "and is freed there")
        #expect(rows[3].color != rows[4].color, "the opened lane has its own color")
        expectConnected(rows)

        for size in [1, 3] {
            var paged = GraphLayout()
            var pagedRows: [GraphRow] = []
            for start in stride(from: 0, to: commits.count, by: size) {
                pagedRows += paged.append(Array(commits[start..<min(start + size, commits.count)]))
            }
            #expect(pagedRows == rows, "pages of \(size) lay out like one batch")
        }
    }

    @Test("graph fixture: bounded width, main's first-parent chain keeps its lane and color, stashes reach their base")
    func graphFixture() async throws {
        let copy = try await Fixtures.copy()
        defer { copy.remove() }
        let repo = copy.repo("graph")
        let env = try await GitInvocation.readEnvironment(profile: nil, base: copy.base, runner: copy.runner, cwd: repo)
        let head = try await copy.git(["rev-parse", "HEAD"], in: repo)
        let stashes = try await StashWorktreeReader.stashes(runner: copy.runner, cwd: repo, env: env)
        #expect(stashes.count == 2)

        var layout = GraphLayout()
        var rows = layout.append(
            [GraphSyntheticRow(kind: .wip, id: "wip", base: head)]
                + stashes.map { GraphSyntheticRow(kind: .stash, id: $0.hash, base: $0.base) })
        for try await page in LogReader.pages(runner: copy.runner, cwd: repo, env: env, pageSize: 4) {
            rows += layout.append(page)
        }
        expectConnected(rows)
        let index = { (hash: String) in rows.firstIndex { $0.node.hash == hash } }

        // 4 branches open at once (main, develop, origin/feature, series) plus stash@{1}'s line.
        #expect(rows.map(\.width).max()! <= 5)

        // The develop merge's second parent line joins main again at the fork, after which one lane is left.
        let merge = try await copy.git(["rev-parse", "v1.0^{commit}"], in: repo)
        let fork = try await copy.git(["merge-base", "v1.0^1", "v1.0^2"], in: repo)
        let mergeRow = try #require(index(merge))
        #expect(rows[mergeRow].bottom.contains { $0.shape == .bendOut })
        let forkRow = try #require(index(fork))
        #expect(rows[forkRow].top.contains { $0.shape == .bendIn })
        #expect(rows[forkRow].bottom.allSatisfy { $0.from == rows[forkRow].lane && $0.to == rows[forkRow].lane })
        #expect(rows[(forkRow + 1)...].allSatisfy { $0.width == 1 }, "every other lane is freed at the join")

        let chain = try await copy.git(["rev-list", "--first-parent", "main"], in: repo).split(separator: "\n")
        let chainRows = try chain.map { try #require(index(String($0))) }
        #expect(Set(chainRows.map { rows[$0].color }).count == 1, "main keeps one color")
        #expect(Set(chainRows.map { rows[$0].lane }).count == 1, "and one lane")
        #expect(rows[0].lane == rows[chainRows[0]].lane, "WIP sits on HEAD's lane")

        for (offset, stash) in stashes.enumerated() {
            let row = offset + 1
            #expect(rows[row].node == .synthetic(GraphSyntheticRow(kind: .stash, id: stash.hash, base: stash.base)))
            #expect(lineEnd(rows, from: row) == index(stash.base), "stash@{\(stash.index)} hangs from its base")
        }
    }

    @Test(
        "benchmark: parse and lay out 50k commits in under 2 s",
        .enabled(if: ProcessInfo.processInfo.environment["HISTQ_BIG_FIXTURE"] != nil))
    func benchmark() async throws {
        let repo = URL(filePath: try #require(ProcessInfo.processInfo.environment["HISTQ_BIG_FIXTURE"]))
        let home = try Fixtures.makeTempDirectory()
        defer { Fixtures.removeTempDirectory(home) }
        let runner = GitRunner(executable: Fixtures.git)
        let env = try await GitInvocation.readEnvironment(
            profile: nil, base: Fixtures.hermeticEnvironment(home: home), runner: runner, cwd: repo)

        let clock = ContinuousClock()
        let start = clock.now
        var layout = GraphLayout()
        var count = 0
        var widest = 0
        for try await page in LogReader.pages(runner: runner, cwd: repo, env: env) {
            for row in layout.append(page) { widest = max(widest, row.width) }
            count += page.count
        }
        let elapsed = clock.now - start
        print("GraphLayout benchmark: \(count) commits parsed and laid out in \(elapsed)")

        #expect(count >= 50_000)
        #expect(widest <= 3, "every topic lane is freed at its fork")
        #expect(elapsed < .seconds(2))
    }

    // MARK: - Helpers

    private func commit(_ hash: String, _ parents: [String]) -> Commit {
        Commit(
            hash: hash, parents: parents, authorName: "A", authorEmail: "a@histq.invalid", authorDate: .distantPast,
            committerDate: .distantPast, subject: hash, body: "")
    }

    /// Every lane (with its color) leaving a row's bottom edge enters the next row's top edge.
    private func expectConnected(_ rows: [GraphRow], sourceLocation: SourceLocation = #_sourceLocation) {
        for (above, below) in zip(rows, rows.dropFirst()) {
            let leaving = Set(above.bottom.map { [$0.to, $0.color] })
            let entering = Set(below.top.map { [$0.from, $0.color] })
            #expect(leaving == entering, sourceLocation: sourceLocation)
        }
    }

    /// Follows the line leaving row `start`'s node down its lane to the row whose node it ends in.
    private func lineEnd(_ rows: [GraphRow], from start: Int) -> Int? {
        let lane = rows[start].lane
        guard rows[start].bottom.contains(where: { $0.from == lane && $0.to == lane }) else { return nil }
        for index in rows.indices.dropFirst(start + 1) {
            guard let segment = rows[index].top.first(where: { $0.from == lane }) else { return nil }
            if segment.to == rows[index].lane { return index }
        }
        return nil
    }
}

private extension GraphRow.Node {
    var hash: String? {
        if case .commit(let hash, _) = self { hash } else { nil }
    }
}
