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

    @Test(
        "a signing method with a blank key and sign-by-default gives git no user.signingKey and no signing",
        arguments: [Profile.Signing.gpg(keyID: ""), .gpg(keyID: "  "), .ssh(keyPath: ""), .ssh(keyPath: " \n")])
    func blankSigningKeyDoesNotSign(signing: Profile.Signing) async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        var profile = Self.profile
        profile.signing = signing
        profile.signByDefault = true
        let env = GitInvocation.environment(profile: profile, base: sandbox.base)

        // Exit 1: the key is not set in any scope.
        let key = try await sandbox.runner.run(
            ["config", "--get", "user.signingKey"], cwd: repo, env: env, allowedExitCodes: [0, 1])
        #expect(key.exitCode == 1, "user.signingKey: \(key.text)")
        let sign = try await sandbox.runner.run(["config", "--get", "commit.gpgSign"], cwd: repo, env: env)
        #expect(sign.text.trimmingCharacters(in: .whitespacesAndNewlines) == "false")
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

    // MARK: - GitHub token

    /// A made-up token; the tests look for it where it must never be. The hosts are `.invalid`, so no real
    /// credential can ever answer for them.
    static let token = "ghp_HistqFakeToken0123456789"
    static let tokenHost = "git.histq.invalid"
    static let tokenHelperKey = "credential.https://git.histq.invalid.helper"

    static var tokenProfile: Profile {
        var profile = profile
        profile.github = .init(host: tokenHost, login: "octo")
        profile.ssh = .keyFile(path: "/keys/id_ed25519")
        return profile
    }

    /// The command-scope config entries of `env`, in order, as `key=value`.
    static func configEntries(_ env: [String: String]) -> [String] {
        (0..<(Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0)).map {
            "\(env["GIT_CONFIG_KEY_\($0)"] ?? "")=\(env["GIT_CONFIG_VALUE_\($0)"] ?? "")"
        }
    }

    /// A user helper in a temp global config (after a reset, so no system helper runs) that touches
    /// `user-helper-ran` and answers `user`/`user-secret`; returns the base using it and the marker.
    static func baseWithUserHelper(_ sandbox: Sandbox) throws -> (base: [String: String], marker: URL, helper: String) {
        let marker = sandbox.root.appending(path: "user-helper-ran")
        let script = sandbox.root.appending(path: "bin/user-helper.sh")
        try Fixtures.writeScript(
            "touch '\(marker.path)'\nprintf 'username=user\\npassword=user-secret\\n'", to: script)
        let helper = "!'\(script.path)'"
        let global = sandbox.root.appending(path: "home/.gitconfig")
        try Data("[credential]\n\thelper =\n\thelper = \(helper)\n".utf8).write(to: global)
        var base = sandbox.base
        base["GIT_CONFIG_GLOBAL"] = global.path
        return (base, marker, helper)
    }

    @Test("only network environments carry the token, in HISTQ_GIT_TOKEN alone; reads, writes and the terminal never")
    func tokenOnlyInNetworkEnvironments() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        let profile = Self.tokenProfile
        let ops = GitOperations(
            runner: sandbox.runner, cwd: repo, profile: profile, base: sandbox.base, token: Self.token)

        let network = GitInvocation.environment(
            profile: profile, base: sandbox.base, access: .network(.fetch), token: Self.token)
        // The operations hold the token for the gate only: no environment of theirs carries it.
        #expect(ops.networkEnv == ops.env)
        #expect(ops.credential?.token == Self.token)
        #expect(network.filter { $0.value.contains(Self.token) }.map(\.key) == ["HISTQ_GIT_TOKEN"])
        #expect(Self.configEntries(network).suffix(2) == [
            "\(Self.tokenHelperKey)=", "\(Self.tokenHelperKey)=\(GitInvocation.tokenHelper)",
        ])
        let networkKeys = try await sandbox.runner.run(
            ["config", "--name-only", "--get-regexp", "^credential\\."], cwd: repo, env: network).text
        #expect(networkKeys.contains(Self.tokenHelperKey), "positive control: git sees the helper")

        let terminal = GitInvocation.terminalEnvironment(profile: profile)
        #expect(Self.configEntries(terminal).contains("user.email=profile@histq.invalid"))
        #expect(terminal["GIT_SSH_COMMAND"] == "ssh -i '/keys/id_ed25519' -o IdentitiesOnly=yes")
        let others: [(String, [String: String])] = [
            ("write", GitInvocation.environment(profile: profile, base: sandbox.base, access: .write, token: Self.token)),
            ("read", GitInvocation.environment(
                profile: profile, base: sandbox.base, access: .read(filterDrivers: []), token: Self.token)),
            ("read in repo", try await GitInvocation.readEnvironment(
                profile: profile, base: sandbox.base, runner: sandbox.runner, cwd: repo)),
            ("operations write", ops.env),
            ("operations network", ops.networkEnv),
            ("terminal", terminal),
        ]
        for (name, env) in others {
            #expect(env["HISTQ_GIT_TOKEN"] == nil, "\(name)")
            #expect(!env.values.contains { $0.contains(Self.token) }, "\(name)")
            #expect(!Self.configEntries(env).contains { $0.hasPrefix("credential.") }, "\(name)")
            if name != "terminal" {
                // Exit 1: no credential key in any scope.
                let keys = try await sandbox.runner.run(
                    ["config", "--get-regexp", "^credential\\."], cwd: repo, env: env, allowedExitCodes: [0, 1])
                #expect(keys.exitCode == 1, "\(name): \(keys.text)")
            }
        }
    }

    /// The network side (fetch, pull and push hooks, with and without the token) is in NetworkTokenTests.
    @Test("a commit's hooks never see the token")
    func commitHooksDoNotSeeToken() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        let dumps = sandbox.root.appending(path: "dumps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dumps, withIntermediateDirectories: true)
        for hook in ["pre-commit", "commit-msg", "post-commit"] {
            try Fixtures.writeScript("env > '\(dumps.appending(path: hook).path)'", to: repo.appending(path: ".git/hooks/\(hook)"))
        }
        let ops = GitOperations(
            runner: sandbox.runner, cwd: repo, profile: Self.tokenProfile, base: sandbox.base, token: Self.token)

        try Data("changed\n".utf8).write(to: repo.appending(path: "tracked.txt"))
        try await ops.stage(["tracked.txt"])
        try await ops.commit(message: "change")

        for hook in ["pre-commit", "commit-msg", "post-commit"] {
            let dump = try String(contentsOf: dumps.appending(path: hook), encoding: .utf8)
            #expect(dump.contains("GIT_CONFIG_COUNT="), "the \(hook) hook ran")
            #expect(!dump.contains("HISTQ_GIT_TOKEN") && !dump.contains(Self.token), "\(hook) saw the token")
        }
    }

    @Test("git credential fill gives the token for the profile's host only, runs no other helper, and the token is in no argument")
    func credentialFillIsScopedToTheHost() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let (base, userMarker, _) = try Self.baseWithUserHelper(sandbox)
        let trace = sandbox.root.appending(path: "trace.txt")
        var env = GitInvocation.environment(
            profile: Self.tokenProfile, base: base, access: .network(.fetch), token: Self.token)
        // GIT_TRACE logs the argv of every command git runs, the helper's shell included.
        env["GIT_TRACE"] = trace.path
        let fill = ["credential", "fill"]

        let mine = try await sandbox.runner.run(
            fill, cwd: sandbox.root, env: env, stdin: Data("protocol=https\nhost=\(Self.tokenHost)\n\n".utf8),
            timeout: .seconds(30))
        #expect(mine.text.contains("username=x-access-token\n"))
        #expect(mine.text.contains("password=\(Self.token)\n"))
        #expect(!FileManager.default.fileExists(atPath: userMarker.path), "the user's helper ran for the profile's host")
        let traced = try String(contentsOf: trace, encoding: .utf8)
        #expect(traced.contains("run_command"), "positive control: the trace lists the helper's command")
        #expect(!traced.contains(Self.token), "the token is in an argument")

        let other = try await sandbox.runner.run(
            fill, cwd: sandbox.root, env: env, stdin: Data("protocol=https\nhost=other.histq.invalid\n\n".utf8),
            timeout: .seconds(30), allowedExitCodes: Set(0...255))
        #expect(!other.text.contains(Self.token) && !other.stderrTail.contains(Self.token))
        // A token-carrying command resets every helper: the user's own would run with HISTQ_GIT_TOKEN in its
        // environment (another host is only reached after a redirect; the gate let no other URL through).
        #expect(!other.text.contains("password="), "a helper answered for another host")
        #expect(!FileManager.default.fileExists(atPath: userMarker.path), "the user's helper ran")
    }

    @Test(
        "a host that could widen or bend the config key, or a token that could break the helper, adds nothing",
        arguments: [
            ("*.histq.invalid", token), ("histq.invalid/x", token), ("user@histq.invalid", token),
            ("histq .invalid", token), ("histq.invalid\n", token), (tokenHost, "two words"),
            (tokenHost, "tok\nhost=evil.invalid"), (tokenHost, #"tok\nhost=evil.invalid"#), (tokenHost, ""),
        ])
    func unsafeHostOrTokenAddsNothing(host: String, token: String) {
        var profile = Self.tokenProfile
        profile.github = .init(host: host, login: "octo")
        let env = GitInvocation.environment(profile: profile, base: [:], access: .network(.fetch), token: token)
        #expect(env["HISTQ_GIT_TOKEN"] == nil)
        #expect(!Self.configEntries(env).contains { $0.hasPrefix("credential.") })
    }

    @Test("the background fetch adds the token helper after its reset and the user's replayed helpers")
    func backgroundFetchCarriesTokenHelperLast() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let (base, _, userHelper) = try Self.baseWithUserHelper(sandbox)
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["remote", "add", "origin", "https://\(Self.tokenHost)/octo/repo.git"], in: repo)

        let env = try await GitInvocation.backgroundFetchEnvironment(
            profile: Self.tokenProfile, base: base, runner: sandbox.runner, cwd: repo, token: Self.token)
        let entries = Self.configEntries(env)
        let reset = try #require(entries.lastIndex(of: "credential.helper="))
        let replayed = try #require(entries.lastIndex(of: "credential.helper=\(userHelper)"))
        #expect(reset < replayed)
        #expect(entries.suffix(2) == [
            "\(Self.tokenHelperKey)=", "\(Self.tokenHelperKey)=\(GitInvocation.tokenHelper)",
        ])
        #expect(env["HISTQ_GIT_TOKEN"] == Self.token)
        #expect(env["GIT_ALLOW_PROTOCOL"] == "https")
        let filled = try await sandbox.runner.run(
            ["credential", "fill"], cwd: repo, env: env,
            stdin: Data("protocol=https\nhost=\(Self.tokenHost)\n\n".utf8), timeout: .seconds(30))
        #expect(filled.text.contains("password=\(Self.token)\n"))

        let withoutToken = try await GitInvocation.backgroundFetchEnvironment(
            profile: Self.tokenProfile, base: base, runner: sandbox.runner, cwd: repo)
        #expect(withoutToken["HISTQ_GIT_TOKEN"] == nil)
        #expect(!Self.configEntries(withoutToken).contains { $0.hasPrefix(Self.tokenHelperKey) })

        // `fetch --all` also contacts a remote on another host: the gate keeps the token back.
        try await sandbox.git(["remote", "add", "other", "https://other.histq.invalid/octo/repo.git"], in: repo)
        let mixed = try await GitInvocation.backgroundFetchEnvironment(
            profile: Self.tokenProfile, base: base, runner: sandbox.runner, cwd: repo, token: Self.token)
        #expect(mixed["HISTQ_GIT_TOKEN"] == nil)
        #expect(mixed["GIT_ALLOW_PROTOCOL"] == "ssh:https:git")
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
