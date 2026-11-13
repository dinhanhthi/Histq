// Security tests for GitInvocation: the profile reaches git and ssh intact, and an automatic read in a
// hostile repo (its `.git/config`, `.git/info/attributes`, hooks, submodules) runs none of the commands the
// repo configures. Every marker case first proves, with the plain (write) environment, that its repo does
// run the marker script, so a passing guard means the override works, not that the fixture never fires.
import Foundation
import HistqCore
import Testing

struct GitInvocationTests {
    static let profile = Profile(
        name: "Work", color: "#E5B13A",
        identity: .init(name: "Profile Person", email: "profile@histq.invalid"))

    /// The automatic status read (StatusReader, task 2.4) and the WIP diff (diff loaders, task 3.2).
    static let statusRead = StatusReader.arguments
    static let wipDiffRead = ["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty"]

    // MARK: - Profile injection

    @Test("the profile identity wins over the repo's own user.*, author.* and committer.* config")
    func profileIdentityWinsOverRepoConfig() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["config", "author.name", "Repo Author"], in: repo)
        try await sandbox.git(["config", "committer.email", "committer@repo.invalid"], in: repo)

        let plain = GitInvocation.environment(profile: nil, base: sandbox.base)
        let repoAuthor = try await sandbox.runner.run(["var", "GIT_AUTHOR_IDENT"], cwd: repo, env: plain).text
        #expect(repoAuthor.hasPrefix("Repo Author <local@histq.invalid> "), "the repo config is in effect")

        let write = GitInvocation.environment(profile: Self.profile, base: sandbox.base)
        let read = try await GitInvocation.readEnvironment(
            profile: Self.profile, base: sandbox.base, runner: sandbox.runner, cwd: repo)
        for env in [write, read] {
            for variable in ["GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"] {
                let ident = try await sandbox.runner.run(["var", variable], cwd: repo, env: env).text
                #expect(ident.hasPrefix("Profile Person <profile@histq.invalid> "), "\(variable): \(ident)")
            }
        }
    }

    @Test("an SSH key path with a space and a single quote reaches ssh as one -i argument")
    func sshKeyPathIsOneArgument() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let fakeBin = sandbox.root.appending(path: "fakebin")
        try Fixtures.writeScript(#"printf '%s\0' "$@""#, to: fakeBin.appending(path: "ssh"))
        let keyPath = sandbox.root.appending(path: "my key's dir/id_ed25519").path
        var profile = Self.profile
        profile.ssh = .keyFile(path: keyPath)
        let env = GitInvocation.environment(profile: profile, base: sandbox.base)
        let command = try #require(env["GIT_SSH_COMMAND"])

        // Git runs GIT_SSH_COMMAND through `/bin/sh -c`; the fake `ssh` prints its argv NUL-separated.
        let shell = GitRunner(executable: URL(filePath: "/bin/sh"))
        let output = try await shell.run(
            ["-c", command], cwd: sandbox.root, env: ["PATH": "\(fakeBin.path):/usr/bin:/bin"],
            timeout: .seconds(10))
        let argv = output.text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        #expect(argv == ["-o", "BatchMode=yes", "-i", keyPath, "-o", "IdentitiesOnly=yes"])
    }

    // MARK: - Untrusted repo config

    @Test("a repo's core.fsmonitor hook does not run during a read")
    func fsmonitorHookDoesNotRun() async throws {
        try await expectReadsRunNothing(controls: [{ _ in ["status"] }], reads: [{ _ in Self.statusRead }]) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            try await sandbox.git(["config", "core.fsmonitor", sandbox.evil.path], in: repo)
            return Built(repo: repo)
        }
    }

    @Test(
        "a filter driver named by .git/info/attributes does not run on a stat-dirty file during a read",
        arguments: [("clean", "evil"), ("process", "evil"), ("clean", "\u{301}evil.x")])
    func filterDriverDoesNotRun(variable: String, driver: String) async throws {
        try await expectReadsRunNothing(
            controls: [{ _ in ["status"] }, { _ in ["diff"] }],
            reads: [{ _ in Self.statusRead }, { _ in Self.wipDiffRead }]
        ) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            try await sandbox.git(["config", "filter.\(driver).\(variable)", sandbox.evil.path], in: repo)
            try Data("* filter=\(driver)\n".utf8).write(to: repo.appending(path: ".git/info/attributes"))
            try Sandbox.makeStatDirty(repo.appending(path: "tracked.txt"))
            return Built(repo: repo)
        }
    }

    @Test(
        "a read fails closed when the config names a filter or diff driver that is not valid UTF-8",
        arguments: [("filter", GitInvocation.ReadSafetyError.filterDriverNotUTF8), ("diff", .diffDriverNotUTF8)])
    func nonUTF8DriverFailsClosed(section: String, error: GitInvocation.ReadSafetyError) async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        // No environment string can carry this name, so its override cannot be expressed.
        let config = try FileHandle(forWritingTo: repo.appending(path: ".git/config"))
        try config.seekToEnd()
        try config.write(contentsOf: Data("[\(section) \"".utf8) + Data([0xFF, 0xFE]) + Data("\"]\n\tx = y\n".utf8))
        try config.close()
        await #expect(throws: error) {
            try await GitInvocation.readEnvironment(
                profile: Self.profile, base: sandbox.base, runner: sandbox.runner, cwd: repo)
        }
    }

    @Test("a populated submodule's own clean filter does not run during a read")
    func submoduleFilterDoesNotRun() async throws {
        // The control drops --ignore-submodules=dirty: that flag is the guard here, since the submodule's
        // filters are not configured in the superproject and so are not listed by the read environment.
        try await expectReadsRunNothing(
            controls: [{ _ in ["status"] }, { _ in ["diff"] }],
            reads: [{ _ in Self.statusRead }, { _ in Self.wipDiffRead }]
        ) { sandbox in
            let source = try await sandbox.makeRepo("sub-source")
            try Data("* filter=evil\n".utf8).write(to: source.appending(path: ".gitattributes"))
            try await sandbox.git(["add", ".gitattributes"], in: source)
            try await sandbox.git(["commit", "-q", "-m", "attributes"], in: source)
            let repo = try await sandbox.makeRepo("super")
            let sub = try await sandbox.addSubmodule(source, as: "sub", in: repo)
            try await sandbox.git(["config", "filter.evil.clean", sandbox.evil.path], in: sub)
            try Sandbox.makeStatDirty(sub.appending(path: "tracked.txt"))
            return Built(repo: repo)
        }
    }

    @Test("a repo's gpg.program does not run for a signed stash commit with log.showSignature set")
    func signatureProgramDoesNotRun() async throws {
        let show: Command = { ["show", "--no-ext-diff", "--no-textconv", $0.revs[0]] }
        try await expectReadsRunNothing(
            controls: [{ _ in ["stash", "list"] }, show], reads: [{ _ in ["stash", "list"] }, show]
        ) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            try await sandbox.git(["config", "log.showSignature", "true"], in: repo)
            try await sandbox.git(["config", "gpg.program", sandbox.evil.path], in: repo)
            let tree = try await sandbox.git(["rev-parse", "HEAD^{tree}"], in: repo)
            let parent = try await sandbox.git(["rev-parse", "HEAD"], in: repo)
            let commit = """
                tree \(tree)
                parent \(parent)
                author Repo Local <local@histq.invalid> 1700000000 +0000
                committer Repo Local <local@histq.invalid> 1700000000 +0000
                gpgsig -----BEGIN PGP SIGNATURE-----
                 iQEzBAABCAAdFiEEZmFrZWZha2VmYWtlZmFrZWZha2U=
                 =fake
                 -----END PGP SIGNATURE-----

                On main: signed stash

                """
            let sha = try await sandbox.git(
                ["hash-object", "-t", "commit", "-w", "--stdin"], in: repo, stdin: Data(commit.utf8))
            try await sandbox.git(
                ["update-ref", "--create-reflog", "-m", "On main: signed stash", "refs/stash", sha], in: repo)
            return Built(repo: repo, revs: [sha])
        }
    }

    @Test("a submodule's diff.external does not run when the superproject sets diff.submodule=diff")
    func submoduleExternalDiffDoesNotRun() async throws {
        let show: Command = { ["show", "--no-ext-diff", "--no-textconv", $0.revs[1]] }
        let diff: Command = { ["diff", "--no-ext-diff", "--no-textconv", $0.revs[0], $0.revs[1]] }
        try await expectReadsRunNothing(controls: [show, diff], reads: [show, diff]) { sandbox in
            let source = try await sandbox.makeRepo("sub-source")
            let repo = try await sandbox.makeRepo("super")
            let sub = try await sandbox.addSubmodule(source, as: "sub", in: repo)
            let before = try await sandbox.git(["rev-parse", "HEAD"], in: repo)
            try await sandbox.git(["config", "user.name", "Repo Local"], in: sub)
            try await sandbox.git(["config", "user.email", "local@histq.invalid"], in: sub)
            try Data("changed\n".utf8).write(to: sub.appending(path: "tracked.txt"))
            try await sandbox.git(["commit", "-q", "-a", "-m", "change"], in: sub)
            try await sandbox.git(["commit", "-q", "-a", "-m", "bump sub"], in: repo)
            let after = try await sandbox.git(["rev-parse", "HEAD"], in: repo)
            try await sandbox.git(["config", "diff.submodule", "diff"], in: repo)
            try await sandbox.git(["config", "diff.external", sandbox.evil.path], in: sub)
            return Built(repo: repo, revs: [before, after])
        }
    }

    @Test("a repo's diff.external does not run for a porcelain diff during a read")
    func externalDiffDoesNotRun() async throws {
        // The read omits --no-ext-diff, so the override is the guard (the read then fails: it may).
        try await expectReadsRunNothing(
            controls: [{ _ in ["diff"] }], reads: [{ _ in ["diff"] }], readsMayFail: true
        ) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            try await sandbox.git(["config", "diff.external", sandbox.evil.path], in: repo)
            try Data("changed\n".utf8).write(to: repo.appending(path: "tracked.txt"))
            return Built(repo: repo)
        }
    }

    @Test(
        "a diff driver named by .git/info/attributes does not run during a read",
        arguments: [("textconv", "evil"), ("command", "evil"), ("textconv", "\u{301}evil.x")])
    func diffDriverDoesNotRun(variable: String, driver: String) async throws {
        // The reads omit --no-ext-diff and --no-textconv, so the overrides are the guard (a read may fail).
        let show: Command = { _ in ["show", "HEAD"] }
        let controls: [Command] = [{ _ in ["diff"] }] + (variable == "textconv" ? [show] : [])
        try await expectReadsRunNothing(
            controls: controls, reads: [{ _ in ["diff"] }, show, { _ in ["log", "-p"] }], readsMayFail: true
        ) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            try await sandbox.git(["config", "diff.\(driver).\(variable)", sandbox.evil.path], in: repo)
            try Data("* diff=\(driver)\n".utf8).write(to: repo.appending(path: ".git/info/attributes"))
            try Data("changed\n".utf8).write(to: repo.appending(path: "tracked.txt"))
            return Built(repo: repo)
        }
    }

    @Test(
        "a partial clone's promisor remote does not fetch a missing blob or branch tip through its uploadpack during a read",
        arguments: [nil, "GIT_NO_LAZY_FETCH", "GIT_ALLOW_PROTOCOL"])
    func lazyFetchDoesNotRun(withoutVariable: String?) async throws {
        // Each guard alone must hold: without GIT_NO_LAZY_FETCH (as on git < 2.44) the transport block
        // stops the fetch, and without the transport block GIT_NO_LAZY_FETCH does. The repo allows the
        // file protocol itself, which beats a command-scope `protocol.allow=never`. The read fails on the
        // missing objects: it may. The shipped log and ref reads touch the branch whose tip is missing.
        let show: Command = { ["show", "--no-ext-diff", "--no-textconv", $0.revs[0]] }
        let shipped: [Command] = [{ _ in LogReader.arguments }, { _ in RefReader.arguments }]
        try await expectReadsRunNothing(
            controls: [show] + shipped, reads: [show] + shipped, readsMayFail: true,
            withoutVariable: withoutVariable
        ) { sandbox in
            let source = try await sandbox.makeRepo("source")
            try Data("only in the source\n".utf8).write(to: source.appending(path: "remote-only.txt"))
            try await sandbox.git(["add", "remote-only.txt"], in: source)
            try await sandbox.git(["commit", "-q", "-m", "remote only"], in: source)
            let blob = try await sandbox.git(["rev-parse", "HEAD:remote-only.txt"], in: source)
            let repo = try await sandbox.makeRepo("repo")
            for (key, value) in [
                ("core.repositoryformatversion", "1"), ("extensions.partialClone", "origin"),
                ("remote.origin.url", source.path), ("remote.origin.promisor", "true"),
                ("remote.origin.uploadpack", sandbox.evil.path), ("protocol.file.allow", "always"),
            ] {
                try await sandbox.git(["config", key, value], in: repo)
            }
            let tree = try await sandbox.git(
                ["mktree", "--missing"], in: repo, stdin: Data("100644 blob \(blob)\tremote-only.txt\n".utf8))
            let commit = try await sandbox.git(["commit-tree", "-m", "missing blob", tree], in: repo)
            // A branch whose tip commit only the source has (`update-ref` would refuse it).
            let sourceHead = try await sandbox.git(["rev-parse", "HEAD"], in: source)
            try Data("\(sourceHead)\n".utf8).write(to: repo.appending(path: ".git/refs/heads/gone"))
            return Built(repo: repo, revs: [commit])
        }
    }

    @Test("a post-index-change hook does not run and the index is not written by a read on a stat-dirty file")
    func indexIsNotRefreshedByRead() async throws {
        try await expectReadsRunNothing(
            controls: [{ _ in ["diff"] }], reads: [{ _ in Self.statusRead }, { _ in Self.wipDiffRead }]
        ) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            try Fixtures.writeScript(
                "touch '\(sandbox.marker.path)'", to: repo.appending(path: ".git/hooks/post-index-change"))
            try Sandbox.makeStatDirty(repo.appending(path: "tracked.txt"))
            return Built(repo: repo)
        }
    }

    // MARK: - Harness

    typealias Command = @Sendable (Built) -> [String]

    /// For each control, a fresh repo from `build` runs the marker with the plain (write) environment. Then
    /// a fresh repo runs every read, in order, with the read environment (less `withoutVariable`, to test
    /// one guard alone): no marker after any of them, each exits 0 (any code if `readsMayFail`), and
    /// `.git/index` is never rewritten.
    func expectReadsRunNothing(
        controls: [Command], reads: [Command], readsMayFail: Bool = false, withoutVariable: String? = nil,
        build: @Sendable (Sandbox) async throws -> Built
    ) async throws {
        for control in controls {
            let sandbox = try await Sandbox()
            defer { sandbox.remove() }
            let built = try await build(sandbox)
            let args = control(built)
            #expect(!sandbox.markerExists, "the setup itself ran the marker")
            let plain = GitInvocation.environment(profile: Self.profile, base: sandbox.base)
            // A control may fail once its marker script exits 1; only the marker matters.
            _ = try? await sandbox.runner.run(
                args, cwd: built.repo, env: plain, timeout: .seconds(30), allowedExitCodes: Set(0...255))
            #expect(sandbox.markerExists, "positive control: `git \(args.joined(separator: " "))` must run the marker")
        }

        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let built = try await build(sandbox)
        let index = built.repo.appending(path: ".git/index")
        let indexDate = try Sandbox.modificationDate(index)
        var env = try await GitInvocation.readEnvironment(
            profile: Self.profile, base: sandbox.base, runner: sandbox.runner, cwd: built.repo)
        if let withoutVariable {
            #expect(env.removeValue(forKey: withoutVariable) != nil, "the read environment sets \(withoutVariable)")
        }
        for read in reads {
            let args = read(built)
            _ = try await sandbox.runner.run(
                args, cwd: built.repo, env: env, timeout: .seconds(30),
                allowedExitCodes: readsMayFail ? Set(0...255) : [0])
            #expect(!sandbox.markerExists, "`git \(args.joined(separator: " "))` ran the marker")
            #expect(try Sandbox.modificationDate(index) == indexDate, "`git \(args.joined(separator: " "))` wrote the index")
        }
    }
}

struct Built: Sendable {
    let repo: URL
    var revs: [String] = []
}

/// A temp folder with its own HOME, hermetic environment and marker script (`evil`, which touches
/// `marker` and exits 1).
struct Sandbox: Sendable {
    let root: URL
    let base: [String: String]
    let runner: GitRunner

    var marker: URL { root.appending(path: "marker") }
    var evil: URL { root.appending(path: "bin/evil.sh") }
    var markerExists: Bool { FileManager.default.fileExists(atPath: marker.path) }

    init() async throws {
        root = try Fixtures.makeTempDirectory("HistqInvocation")
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        base = Fixtures.hermeticEnvironment(home: home)
        runner = GitRunner(executable: Fixtures.git)
        try Fixtures.writeScript("touch '\(marker.path)'\nexit 1", to: root.appending(path: "bin/evil.sh"))
    }

    func remove() { Fixtures.removeTempDirectory(root) }

    /// Runs a setup command with the hermetic environment; returns its trimmed stdout.
    @discardableResult
    func git(_ args: [String], in dir: URL, stdin: Data? = nil) async throws -> String {
        let result = try await runner.run(args, cwd: dir, env: base, stdin: stdin, timeout: .seconds(30))
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A repo with a repo-local identity and one commit of `tracked.txt`.
    func makeRepo(_ name: String) async throws -> URL {
        let repo = root.appending(path: name, directoryHint: .isDirectory)
        try await git(["init", "-q", "-b", "main", repo.path], in: root)
        try await git(["config", "user.name", "Repo Local"], in: repo)
        try await git(["config", "user.email", "local@histq.invalid"], in: repo)
        try Data("hello\n".utf8).write(to: repo.appending(path: "tracked.txt"))
        try await git(["add", "tracked.txt"], in: repo)
        try await git(["commit", "-q", "-m", "initial"], in: repo)
        return repo
    }

    /// Clones `source` as the populated submodule `path` of `repo` and commits it; returns its folder.
    func addSubmodule(_ source: URL, as path: String, in repo: URL) async throws -> URL {
        try await git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", source.path, path], in: repo)
        try await git(["commit", "-q", "-m", "add \(path)"], in: repo)
        return repo.appending(path: path, directoryHint: .isDirectory)
    }

    /// Changes the file's mtime but not its content, so git must re-read it to know it is unchanged.
    static func makeStatDirty(_ file: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: file.path)
    }

    static func modificationDate(_ file: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    }
}
