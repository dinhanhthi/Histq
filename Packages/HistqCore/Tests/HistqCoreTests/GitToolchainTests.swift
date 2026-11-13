// Where git and its PATH come from: automatic reads use a fixed git and a fixed PATH and never wait for the login
// shell; writes use the login shell's PATH, cached in a data-only file that is validated on load.
import Foundation
import HistqCore
import Synchronization
import Testing

struct GitToolchainTests {
    // MARK: - Reads never wait for the login shell

    @Test("the whole read setup (git, base environment, read environment, status) runs while the login shell hangs")
    func readsDoNotWaitForTheLoginShell() async throws {
        let shell = GatedShell()
        defer { shell.open(with: nil) }
        let login = LoginShellPath(cacheFile: nil, resolver: shell.resolver)
        let pending = Task { await login.value() }
        defer { pending.cancel() }
        await shell.waitUntilCalled()

        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        let git = try await GitExecutable.resolve()
        let runner = GitRunner(executable: git.url)
        let base = GitInvocation.baseEnvironment()
        let read = try await GitInvocation.readEnvironment(profile: nil, base: base, runner: runner, cwd: repo)
        _ = try await StatusReader.read(runner: runner, cwd: repo, env: read)

        #expect(!shell.isOpen, "the login shell answered before the reads finished")
        #expect(base["PATH"] == GitExecutable.fixedPath)
        #expect(read["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("the read environment keeps every read-safety key, with the fixed PATH and only the agent variables inherited")
    func readSafetyKeysAreUnchanged() {
        let base = GitInvocation.baseEnvironment(
            home: "/Users/someone", inherited: ["SSH_AUTH_SOCK": "/tmp/agent", "USER": "someone", "SECRET": "no"])
        let read = GitInvocation.environment(
            profile: nil, base: base, access: .read(filterDrivers: ["lfs"], diffDrivers: ["img"]))
        let config: [(String, String)] = [
            ("core.fsmonitor", "false"), ("log.showSignature", "false"), ("diff.submodule", "short"),
            ("diff.autoRefreshIndex", "false"), ("core.hooksPath", "/dev/null"), ("diff.external", ""),
            ("i18n.logOutputEncoding", "UTF-8"),
            ("filter.lfs.clean", ""), ("filter.lfs.smudge", ""), ("filter.lfs.process", ""),
            ("filter.lfs.required", "false"), ("diff.img.textconv", ""), ("diff.img.command", ""),
        ]
        var expected = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": "/Users/someone", "SSH_AUTH_SOCK": "/tmp/agent", "USER": "someone",
            "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C", "GIT_SSH_COMMAND": "ssh -o BatchMode=yes",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1", "GIT_ALLOW_PROTOCOL": "",
            "GIT_CONFIG_COUNT": String(config.count),
        ]
        for (index, (key, value)) in config.enumerated() {
            expected["GIT_CONFIG_KEY_\(index)"] = key
            expected["GIT_CONFIG_VALUE_\(index)"] = value
        }
        #expect(read == expected)
    }

    // MARK: - Fixed-folder git

    @Test("resolve takes the first folder with an executable git, skipping missing, non-executable and relative ones")
    func resolveSearchesTheFoldersInOrder() async throws {
        let root = try Fixtures.makeTempDirectory()
        defer { Fixtures.removeTempDirectory(root) }
        let empty = root.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let plainFile = root.appending(path: "plain/git")
        try FileManager.default.createDirectory(
            at: plainFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("echo 'git version 2.50.0'\n".utf8).write(to: plainFile)
        let second = root.appending(path: "second/git")
        let third = root.appending(path: "third/git")
        try Fixtures.writeScript("echo 'git version 2.40.1'", to: second)
        try Fixtures.writeScript("echo 'git version 2.41.0'", to: third)
        let folders = [empty.path, plainFile.deletingLastPathComponent().path, "relative",
                       second.deletingLastPathComponent().path, third.deletingLastPathComponent().path]

        let found = try await GitExecutable.resolve(directories: folders)
        #expect(found.url.path == second.path)
        #expect(found.version == GitVersion(2, 40, 1))

        let overridden = try await GitExecutable.resolve(override: third.path, directories: folders)
        #expect(overridden.url.path == third.path, "the gitPath override beats the folders")

        await #expect(throws: GitExecutableError.notFound) {
            try await GitExecutable.resolve(directories: [empty.path])
        }
    }

    @Test("the default folders are Homebrew (Apple silicon, then Intel), then /usr/bin")
    func defaultSearchOrder() {
        #expect(GitExecutable.searchDirectories == ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
    }

    // MARK: - Login shell PATH cache

    @Test(
        "a cached PATH that is not a list of absolute folders is rejected",
        arguments: ["", "relative/bin:/usr/bin", "/usr/bin::/bin", ":/usr/bin", "/usr/bin:", "/usr/bin\n",
                    "/usr/bin\n/bin", "/usr/bin\r", "/usr/b\0in", ".:/usr/bin",
                    // One Swift Character each, but the OS sees a newline / a relative entry.
                    "/usr/bin\r\n/evil", "/a:\u{301}b"])
    func invalidCacheIsRejected(path: String) {
        #expect(!LoginShellPath.isValid(path))
    }

    @Test("a PATH of absolute folders is a valid cache, missing folders included")
    func validCacheIsAccepted() {
        #expect(LoginShellPath.isValid("/usr/bin"))
        #expect(LoginShellPath.isValid("/Users/me/.cargo/bin:/no/such/folder:/usr/bin:/bin"))
    }

    @Test("a valid cache answers at once while the shell runs, then the shell's PATH replaces it in the file")
    func cacheAnswersAtOnceThenRefreshes() async throws {
        let folder = try Fixtures.makeTempDirectory()
        defer { Fixtures.removeTempDirectory(folder) }
        // The state folder may not exist yet at launch: the cache creates it.
        let file = folder.appending(path: "state/login-path")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("/cached/bin:/usr/bin".utf8).write(to: file)
        let shell = GatedShell()
        defer { shell.open(with: nil) }
        let login = LoginShellPath(cacheFile: file, resolver: shell.resolver)

        #expect(await login.value() == "/cached/bin:/usr/bin")
        await shell.waitUntilCalled()
        #expect(!shell.isOpen)

        shell.open(with: "/fresh/bin:/usr/bin")
        let fresh = "/fresh/bin:/usr/bin:/opt/homebrew/bin:/usr/local/bin"
        #expect(try await Self.poll { await login.value() == fresh })
        #expect(try String(contentsOf: file, encoding: .utf8) == fresh)
        #expect(shell.calls == 1, "one shell run per instance")
    }

    @Test("without a cache the PATH waits for the shell, drops relative entries and is cached for the next launch")
    func noCacheWaitsForTheShell() async throws {
        let folder = try Fixtures.makeTempDirectory()
        defer { Fixtures.removeTempDirectory(folder) }
        let file = folder.appending(path: "missing/login-path")
        let shell = GatedShell()
        let login = LoginShellPath(cacheFile: file, resolver: shell.resolver)
        let value = Task { await login.value() }
        await shell.waitUntilCalled()
        shell.open(with: ".:/custom/bin::relative:\u{301}evil:/usr/bin")

        let expected = "/custom/bin:/usr/bin:/opt/homebrew/bin:/usr/local/bin"
        #expect(await value.value == expected)
        #expect(try String(contentsOf: file, encoding: .utf8) == expected)
        let nextLaunch = LoginShellPath(cacheFile: file, resolver: { nil })
        #expect(await nextLaunch.value() == expected)
    }

    @Test(
        "an invalid cache file is ignored: the PATH waits for the shell",
        arguments: ["relative/bin:/usr/bin", "/usr/bin::/bin", "/usr/bin\n", "/usr/bin\n/evil", "/usr/b\0in", "",
                    "/usr/bin\r\n/evil", "/a:\u{301}b"])
    func invalidCacheFileIsIgnored(contents: String) async throws {
        let folder = try Fixtures.makeTempDirectory()
        defer { Fixtures.removeTempDirectory(folder) }
        let file = folder.appending(path: "login-path")
        try Data(contents.utf8).write(to: file)
        let login = LoginShellPath(cacheFile: file, resolver: { "/shell/bin" })
        #expect(await login.value() == "/shell/bin:/opt/homebrew/bin:/usr/local/bin")
    }

    @Test("a failed shell keeps a valid cache and never writes its fallback PATH to the cache")
    func failedShellIsNotCached() async throws {
        let folder = try Fixtures.makeTempDirectory()
        defer { Fixtures.removeTempDirectory(folder) }
        let cached = folder.appending(path: "cached")
        try Data("/cached/bin".utf8).write(to: cached)
        let keeps = LoginShellPath(cacheFile: cached, resolver: { nil })
        #expect(await keeps.value() == "/cached/bin")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await keeps.value() == "/cached/bin")
        #expect(try String(contentsOf: cached, encoding: .utf8) == "/cached/bin")

        let none = folder.appending(path: "none")
        let fallback = LoginShellPath(cacheFile: none, resolver: { nil })
        #expect(!(await fallback.value()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: none.path))
    }

    // MARK: - Helpers

    /// Polls `condition` every 20 ms for up to 5 s.
    private static func poll(_ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try await condition()
    }
}

/// A fake login shell that answers only once the test opens it.
private final class GatedShell: Sendable {
    private struct State {
        var calls = 0
        var answer: String??
        var waiters: [CheckedContinuation<String?, Never>] = []
        var callWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var calls: Int { state.withLock { $0.calls } }
    var isOpen: Bool { state.withLock { $0.answer != nil } }

    var resolver: @Sendable () async -> String? {
        { [self] in
            await withCheckedContinuation { continuation in
                let (answer, callWaiters) = state.withLock { state -> (String??, [CheckedContinuation<Void, Never>]) in
                    state.calls += 1
                    let waiters = state.callWaiters
                    state.callWaiters = []
                    if state.answer == nil { state.waiters.append(continuation) }
                    return (state.answer, waiters)
                }
                callWaiters.forEach { $0.resume() }
                if let answer { continuation.resume(returning: answer) }
            }
        }
    }

    /// Returns once the resolver was called.
    func waitUntilCalled() async {
        await withCheckedContinuation { continuation in
            let called = state.withLock { state in
                if state.calls == 0 { state.callWaiters.append(continuation) }
                return state.calls > 0
            }
            if called { continuation.resume() }
        }
    }

    /// Answers every pending and later call with `answer`; only the first open counts.
    func open(with answer: String?) {
        let waiters = state.withLock { state -> [CheckedContinuation<String?, Never>] in
            guard state.answer == nil else { return [] }
            state.answer = .some(answer)
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume(returning: answer) }
    }
}
