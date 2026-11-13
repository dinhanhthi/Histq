// Key feature tests for the conflict editor's model (task 3.3) on a private copy of the `conflict` fixture
// (main merging feature; A = :2 = main, B = :3 = feature): long.txt has as many conflicts as
// `git merge-file` reports; the initial Output applies one-sided changes and shows the base for unresolved
// conflicts; A for #1, B for #2 and A+B for #3 gives the expected file byte for byte; the line map links
// conflict starts across panes; a manual edit survives ticks in another region; modify/delete and add/add
// load as their own cases; a Latin-1 conflict keeps its bytes in Output; a binary conflict is never text.
import Foundation
import HistqCore
import Testing

struct ThreeWayMergeTests {
    struct Repo {
        let copy: FixtureCopy
        let repo: URL
        let readEnv: [String: String]

        init() async throws {
            copy = try await Fixtures.copy()
            repo = copy.repo("conflict")
            readEnv = try await GitInvocation.readEnvironment(profile: nil, base: copy.base, runner: copy.runner, cwd: repo)
        }

        func load(_ path: String) async throws -> ConflictSource {
            try await ConflictSource.load(
                path: path, labels: ConflictLabels(a: "main", b: "feature"), runner: copy.runner, cwd: repo, env: readEnv)
        }

        func longMerge() async throws -> ThreeWayMerge {
            try #require(try await load("long.txt").merge())
        }

        /// Adds unmerged index entries for `path`: stage 1 = `base` (when given), 2 = `a`, 3 = `b`.
        func stageConflict(_ path: String, base: Data?, a: Data, b: Data) async throws {
            var info = ""
            for (stage, blob) in [(1, base), (2, a), (3, b)] {
                guard let blob else { continue }
                let result = try await copy.runner.run(["hash-object", "-w", "--stdin"], cwd: repo, env: copy.base, stdin: blob)
                info += "100644 \(result.text.trimmingCharacters(in: .whitespacesAndNewlines)) \(stage)\t\(path)\n"
            }
            _ = try await copy.runner.run(["update-index", "--index-info"], cwd: repo, env: copy.base, stdin: Data(info.utf8))
        }
    }

    @Test("long.txt has as many conflicts as git merge-file reports (3)")
    func conflictCountMatchesGit() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let merge = try await fx.longMerge()
        let gitResult = try await fx.copy.runner.run(
            ["merge-file", "-p", "--object-id", ":2:long.txt", ":1:long.txt", ":3:long.txt"], cwd: fx.repo,
            env: fx.copy.base, allowedExitCodes: Set(0...127))
        #expect(gitResult.exitCode == 3)
        #expect(merge.conflictCount == Int(gitResult.exitCode))
    }

    @Test("the initial Output applies one-sided changes and shows the base for unresolved conflicts")
    func initialOutput() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let merge = try await fx.longMerge()
        let output = merge.outputLines
        #expect(output.count == 100)
        #expect(output[19] == "line 20: nội dung feature\n")
        #expect(output[54] == "line 55: nội dung main\n")
        #expect(merge.unresolvedCount == 3)
        for (k, line) in [10, 40, 70].enumerated() {
            let region = merge.regions[merge.conflictRegions[k]]
            #expect(region.isUnresolved)
            #expect(Array(output[region.output]) == ["line \(line): nội dung gốc\n"])
            #expect(Array(merge.aLines[region.a]) == ["line \(line): nội dung main\n"])
            #expect(Array(merge.bLines[region.b]) == ["line \(line): nội dung feature\n"])
        }
    }

    @Test("A for #1, B for #2 and A+B for #3 equals expected/long-A1-B2-AB3.txt")
    func compositionMatchesExpected() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        var merge = try await fx.longMerge()
        merge.setTicked(true, side: .a, conflict: 0)
        merge.setTicked(true, side: .b, conflict: 1)
        merge.setTicked(true, side: .a, conflict: 2)
        merge.setTicked(true, side: .b, conflict: 2)
        let expected = try Data(contentsOf: fx.copy.root.appending(path: "expected/long-A1-B2-AB3.txt"))
        #expect(merge.unresolvedCount == 0)
        #expect(merge.outputData == expected)
    }

    @Test("the line map takes conflict k's start in A to its start in B and Output")
    func lineMapLinksConflictStarts() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        var merge = try await fx.longMerge()
        // A+B for #1 shifts every later Output line by one, so Output no longer shares A's numbering.
        merge.setTicked(true, side: .a, conflict: 0)
        merge.setTicked(true, side: .b, conflict: 0)
        for k in 0..<merge.conflictCount {
            let startA = merge.conflictStart(k, in: .a)
            #expect(merge.line(startA, in: .a, to: .b) == merge.conflictStart(k, in: .b))
            #expect(merge.line(startA, in: .a, to: .output) == merge.conflictStart(k, in: .output))
        }
        #expect(merge.conflictStart(1, in: .output) == merge.conflictStart(1, in: .a) + 1)
    }

    @Test("a manual edit in one region survives a checkbox change in another")
    func manualEditSurvivesTickElsewhere() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        var merge = try await fx.longMerge()
        let first = merge.conflictRegions[0]
        let laterStart = merge.conflictStart(2, in: .output)
        merge.setManualText("hand merged 10\nand one more line\n", region: first)
        merge.setTicked(true, side: .b, conflict: 1)

        let region = merge.regions[first]
        #expect(region.isManual && !region.isUnresolved)
        #expect(Array(merge.outputLines[region.output]) == ["hand merged 10\n", "and one more line\n"])
        #expect(merge.outputLines[merge.regions[merge.conflictRegions[1]].output] == ["line 40: nội dung feature\n"])
        #expect(merge.conflictStart(2, in: .output) == laterStart + 1)
        #expect(merge.unresolvedCount == 1)
    }

    @Test("gone.txt loads as modify/delete and add.txt as add/add without a base")
    func otherConflictKinds() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let gone = try await fx.load("gone.txt")
        guard case .modifyDelete(let base, let a, let b) = gone.content else {
            Issue.record("gone.txt: \(gone.content)")
            return
        }
        #expect(base != nil && a != nil && b == nil)
        #expect(gone.merge() == nil)

        let add = try await fx.load("add.txt")
        guard case .text(let addBase, _, _) = add.content else {
            Issue.record("add.txt: \(add.content)")
            return
        }
        #expect(addBase == nil)
        #expect(add.merge()?.conflictCount == 1)
    }

    @Test("a Latin-1 conflict keeps its original bytes in Output, and a change of one invalid byte counts")
    func nonUTF8BytesRoundTrip() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        // Latin-1: 0xE8/0xE9/0xEA all decode to U+FFFD, so only a byte comparison sees line 2 change.
        let base: [[UInt8]] = [Array("caf".utf8) + [0xE9, 0x0A], [0x78, 0xE9, 0x0A], [0x6D, 0xE0, 0x0A], [0x74, 0xFF]]
        let a: [[UInt8]] = [base[0], [0x78, 0xE8, 0x0A], base[2], base[3]]
        let b: [[UInt8]] = [base[0], [0x78, 0xEA, 0x0A], base[2], [0x74, 0xFE]]
        try await fx.stageConflict(
            "latin1.txt", base: Data(base.joined()), a: Data(a.joined()), b: Data(b.joined()))
        let source = try await fx.load("latin1.txt")
        guard case .text = source.content else {
            Issue.record("latin1.txt: \(source.content)")
            return
        }
        var merge = try #require(source.merge())
        #expect(merge.conflictCount == 1)
        #expect(merge.regions.map(\.kind) == [.unchanged, .conflict, .unchanged, .changedInB])
        // Unresolved: the base bytes for the conflict, B's bytes for B's one-sided change.
        #expect(merge.outputData == Data([base[0], base[1], base[2], b[3]].joined()))
        merge.setTicked(true, side: .a, conflict: 0)
        #expect(merge.outputData == Data([a[0], a[1], a[2], b[3]].joined()))
    }

    @Test("a conflict with a NUL byte in a stage loads as binary, never as a text merge")
    func binaryConflictIsNotText() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.stageConflict(
            "image.png", base: Data([0x89, 0x50, 0x00, 0x01]), a: Data([0x89, 0x50, 0x00, 0x02]),
            b: Data([0x89, 0x50, 0x00, 0x03]))
        let source = try await fx.load("image.png")
        guard case .binary(let base, let a, let b) = source.content else {
            Issue.record("image.png: \(source.content)")
            return
        }
        #expect(base == Data([0x89, 0x50, 0x00, 0x01]))
        #expect(a == Data([0x89, 0x50, 0x00, 0x02]) && b == Data([0x89, 0x50, 0x00, 0x03]))
        #expect(source.merge() == nil)
    }
}
