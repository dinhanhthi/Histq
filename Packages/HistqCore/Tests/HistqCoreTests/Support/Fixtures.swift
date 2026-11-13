// Shared test support: temp folders, the hermetic base environment every test git call must use (so the
// user's ~/.gitconfig (signing, hooks, pull settings) and the system config never affect CORE tests), and
// the fixture repos of `scripts/make-fixtures.sh`, built once per test run and copied for each test.
import Foundation
import HistqCore
import Synchronization

enum Fixtures {
    /// The git the tests run (Apple's; the Command Line Tools are required to build anyway).
    static let git = URL(filePath: "/usr/bin/git")

    /// A new empty folder under the system temp folder. Remove it with `removeTempDirectory`.
    static func makeTempDirectory(_ prefix: String = "HistqTests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeTempDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// No global or system config, HOME in `home`, no prompts, signing off (as command-scope config, so
    /// `GitInvocation` appends after it).
    static func hermeticEnvironment(home: URL) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C",
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "commit.gpgSign",
            "GIT_CONFIG_VALUE_0": "false",
            "GIT_CONFIG_KEY_1": "tag.gpgSign",
            "GIT_CONFIG_VALUE_1": "false",
        ]
    }

    /// Writes an executable script.
    static func writeScript(_ body: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Fixture repos

    /// `scripts/make-fixtures.sh`, found from this file (`Packages/HistqCore/Tests/HistqCoreTests/Support`).
    static let script = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "scripts/make-fixtures.sh")

    /// The fixture root of this test run, built on first use (tests run in parallel; a `static let` is
    /// initialized once) and removed when the test process exits.
    private static let built = Task<URL, Error> {
        let root = try makeTempDirectory("HistqFixtures")
        let home = try makeTempDirectory("HistqFixturesHome")
        defer { removeTempDirectory(home) }
        builtRoot.withLock { $0 = root }
        atexit {
            if let root = Fixtures.builtRoot.withLock({ $0 }) { try? FileManager.default.removeItem(at: root) }
        }
        let runner = GitRunner(executable: URL(filePath: "/bin/bash"))
        _ = try await runner.run(
            [script.path, root.appending(path: "fx").path], cwd: root, env: hermeticEnvironment(home: home),
            timeout: .seconds(120))
        return root.appending(path: "fx")
    }

    private static let builtRoot = Mutex<URL?>(nil)

    /// A private copy of the whole fixture root (`graph`, `graph-origin.git`, `graph-wt`, `conflict`,
    /// `conflict-rebase`, `expected`): the relative remote `../graph-origin.git` and the relative worktree
    /// link to `../graph-wt` only resolve next to their siblings. Remove it with `remove()`.
    static func copy() async throws -> FixtureCopy {
        let source = try await built.value
        let folder = try makeTempDirectory("HistqFixtureCopy")
        do {
            let root = folder.appending(path: "fx", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: source, to: root)
            let home = folder.appending(path: "home", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            return FixtureCopy(folder: folder, root: root, base: hermeticEnvironment(home: home))
        } catch {
            removeTempDirectory(folder)
            throw error
        }
    }
}

/// One test's copy of the fixture root, with the hermetic base environment its git calls must use.
struct FixtureCopy: Sendable {
    let folder: URL
    /// The copied fixture root, holding `graph`, `graph-origin.git`, `graph-wt`, `conflict`, ...
    let root: URL
    /// `Fixtures.hermeticEnvironment` with HOME in this copy's own folder.
    let base: [String: String]
    let runner = GitRunner(executable: Fixtures.git)

    func repo(_ name: String) -> URL { root.appending(path: name, directoryHint: .isDirectory) }

    /// Runs git with the hermetic base environment and returns its stdout without the final newline.
    @discardableResult
    func git(_ args: [String], in repo: URL) async throws -> String {
        let text = try await runner.run(args, cwd: repo, env: base, timeout: .seconds(30)).text
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    func remove() { Fixtures.removeTempDirectory(folder) }
}
