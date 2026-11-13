// Security tests for the background fetch environment (auto-fetch): a fetch nobody clicked, in a repo whose
// `.git/config`, hooks and alternates may be hostile, runs none of the commands the repo configures, and
// only the user's own credential helpers. As in GitInvocationTests, every marker case first proves, with the
// plain (write) environment, that its repo does run the marker script. No case touches the network: the
// "ssh" remotes go through a fake `ssh` that runs `git upload-pack` on a local folder, and the git:// remote
// is a closed port on the loopback address.
import Foundation
import HistqCore
import Testing

struct BackgroundFetchTests {
    static let fetch = ["fetch", "--all"]

    // MARK: - Transports and fetch-time commands

    @Test(
        "a repo's remote config does not run a local command during a background fetch",
        arguments: ["uploadpack", "ext", "insteadOf", "vcs", "gitProxy"])
    func remoteConfigDoesNotRun(trick: String) async throws {
        try await expectFetchRunsNothing(fetchSucceeds: false) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            let source = try await sandbox.makeRepo("source")
            let evil = sandbox.evil.path
            let config: [(String, String)] = switch trick {
            case "uploadpack":
                // A file:// remote runs `uploadpack` on this Mac.
                [("remote.origin.url", "file://" + source.path),
                 ("remote.origin.uploadpack", evil), ("protocol.file.allow", "always")]
            case "ext":
                [("remote.origin.url", "ext::\(evil)"), ("protocol.ext.allow", "always")]
            case "insteadOf":
                // An innocent looking URL that the repo rewrites to an ext:: command.
                [("remote.origin.url", "histq-test:repo"), ("url.ext::\(evil).insteadOf", "histq-test:repo"),
                 ("protocol.ext.allow", "always")]
            case "vcs":
                // `git-remote-evil` is in the fake bin folder on PATH.
                [("remote.origin.url", "anything"), ("remote.origin.vcs", "evil")]
            default:
                // A closed port on the loopback address: without the proxy the connection is refused at once.
                [("remote.origin.url", "git://127.0.0.1:1/repo"), ("core.gitProxy", evil)]
            }
            for (key, value) in config {
                try await sandbox.git(["config", key, value], in: repo)
            }
            return repo
        }
    }

    @Test("a reference-transaction hook does not run while a background fetch updates refs over ssh")
    func referenceTransactionHookDoesNotRun() async throws {
        try await expectFetchRunsNothing(fetchSucceeds: true) { sandbox in
            let repo = try await Self.makeRepoWithSSHRemote(sandbox)
            // Written after the setup, whose own commits would run it.
            try Fixtures.writeScript(
                "touch '\(sandbox.marker.path)'", to: repo.appending(path: ".git/hooks/reference-transaction"))
            return repo
        }
    }

    @Test("a repo's core.alternateRefsCommand does not run for its alternates during a background fetch")
    func alternateRefsCommandDoesNotRun() async throws {
        try await expectFetchRunsNothing(fetchSucceeds: true) { sandbox in
            let repo = try await Self.makeRepoWithSSHRemote(sandbox)
            let alternate = try await sandbox.makeRepo("alternate")
            try Data(alternate.appending(path: ".git/objects").path.utf8)
                .write(to: repo.appending(path: ".git/objects/info/alternates"))
            try await sandbox.git(["config", "core.alternateRefsCommand", sandbox.evil.path], in: repo)
            return repo
        }
    }

    @Test("the background fetch's ssh gives up on a dead host and keeps the profile's options")
    func sshCommandHasTimeouts() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        let env = try await GitInvocation.backgroundFetchEnvironment(
            profile: GitInvocationTests.profile, base: sandbox.base, runner: sandbox.runner, cwd: repo)
        #expect(env["GIT_SSH_COMMAND"]
            == "ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2")
    }

    // MARK: - Repo network config

    @Test(
        "a repo with its own http or proxy config is not fetched in the background",
        arguments: ["http.proxy", "urlSSLVerify", "remoteProxy", "includedValueless"])
    func repoNetworkConfigSkipsFetch(trick: String) async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        // A repo-local helper too: the fetch is skipped before anything, this helper included, could run.
        try await sandbox.git(["config", "credential.helper", "!'\(sandbox.evil.path)'"], in: repo)
        let expected: String
        switch trick {
        case "http.proxy":
            try await sandbox.git(["config", "http.proxy", "http://127.0.0.1:1"], in: repo)
            expected = "http.proxy"
        case "urlSSLVerify":
            try await sandbox.git(["config", "http.https://example.invalid.sslVerify", "false"], in: repo)
            expected = "http.https://example.invalid.sslverify"
        case "remoteProxy":
            try await sandbox.git(["config", "remote.origin.proxy", "http://127.0.0.1:1"], in: repo)
            expected = "remote.origin.proxy"
        default:
            // A file the repo includes has the repo's scope; a valueless key counts too.
            let included = sandbox.root.appending(path: "included.config")
            try Data("[http]\n\tsslVerify\n".utf8).write(to: included)
            try await sandbox.git(["config", "include.path", included.path], in: repo)
            expected = "http.sslverify"
        }

        await #expect(throws: GitInvocation.BackgroundFetchError.repoSetsNetworkConfig(keys: [expected])) {
            try await GitInvocation.backgroundFetchEnvironment(
                profile: GitInvocationTests.profile, base: sandbox.base, runner: sandbox.runner, cwd: repo)
        }
        #expect(!sandbox.markerExists, "the listing ran the repo's helper")
    }

    @Test("the user's own global http and proxy config does not stop a background fetch")
    func globalNetworkConfigIsAllowed() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let global = sandbox.root.appending(path: "home/.gitconfig")
        try Data("""
            [http]
            \tproxy = http://127.0.0.1:1
            [http "https://example.invalid"]
            \tsslVerify = false
            [remote "origin"]
            \tproxy = http://127.0.0.1:1

            """.utf8).write(to: global)
        var base = sandbox.base
        base["GIT_CONFIG_GLOBAL"] = global.path
        let repo = try await sandbox.makeRepo("repo")
        let env = try await GitInvocation.backgroundFetchEnvironment(
            profile: GitInvocationTests.profile, base: base, runner: sandbox.runner, cwd: repo)
        #expect(env["GIT_ALLOW_PROTOCOL"] == "ssh:https:git")
    }

    // MARK: - Credentials

    @Test("a repo's credential helpers do not run, the user's global helper does")
    func repoCredentialHelpersDoNotRun() async throws {
        let approve = ["credential", "approve"]
        let input = Data("protocol=https\nhost=example.invalid\nusername=u\npassword=p\n\n".utf8)
        for control in [true, false] {
            let sandbox = try await Sandbox()
            defer { sandbox.remove() }
            let good = sandbox.root.appending(path: "good-marker")
            let goodHelper = sandbox.root.appending(path: "bin/good.sh")
            try Fixtures.writeScript("touch '\(good.path)'", to: goodHelper)
            let global = sandbox.root.appending(path: "home/.gitconfig")
            try Data("[credential]\n\thelper = !'\(goodHelper.path)'\n".utf8).write(to: global)
            var base = sandbox.base
            base["GIT_CONFIG_GLOBAL"] = global.path
            let repo = try await sandbox.makeRepo("repo")
            for key in ["credential.helper", "credential.https://example.invalid.helper"] {
                try await sandbox.git(["config", "--add", key, "!'\(sandbox.evil.path)'"], in: repo)
            }

            let env: [String: String]
            if control {
                env = GitInvocation.environment(profile: GitInvocationTests.profile, base: base)
            } else {
                let helpers = try await GitInvocation.credentialHelpers(
                    runner: sandbox.runner, cwd: repo,
                    env: GitInvocation.environment(profile: nil, base: base, access: .read(filterDrivers: [])))
                #expect(helpers == [.init(key: "credential.helper", value: "!'\(goodHelper.path)'")])
                env = try await GitInvocation.backgroundFetchEnvironment(
                    profile: GitInvocationTests.profile, base: base, runner: sandbox.runner, cwd: repo)
            }
            _ = try await sandbox.runner.run(
                approve, cwd: repo, env: env, stdin: input, timeout: .seconds(30), allowedExitCodes: Set(0...255))
            #expect(FileManager.default.fileExists(atPath: good.path), "the global helper ran (control: \(control))")
            if control {
                #expect(sandbox.markerExists, "positive control: the repo's helpers must run with the write env")
            } else {
                #expect(!sandbox.markerExists, "a repo-local credential helper ran")
            }
        }
    }

    @Test("a repo's core.askPass does not run when git needs a password during a background fetch")
    func repoAskPassDoesNotRun() async throws {
        let fill = ["credential", "fill"]
        let input = Data("protocol=https\nhost=example.invalid\n\n".utf8)
        for control in [true, false] {
            let sandbox = try await Sandbox()
            defer { sandbox.remove() }
            let repo = try await sandbox.makeRepo("repo")
            try await sandbox.git(["config", "core.askPass", sandbox.evil.path], in: repo)
            let env = control
                ? GitInvocation.environment(profile: GitInvocationTests.profile, base: sandbox.base)
                : try await GitInvocation.backgroundFetchEnvironment(
                    profile: GitInvocationTests.profile, base: sandbox.base, runner: sandbox.runner, cwd: repo)
            let result = try await sandbox.runner.run(
                fill, cwd: repo, env: env, stdin: input, timeout: .seconds(30), allowedExitCodes: Set(0...255))
            #expect(result.exitCode != 0, "no credential to fill")
            #expect(sandbox.markerExists == control, "core.askPass ran: \(sandbox.markerExists) (control: \(control))")
        }
    }

    // MARK: - Harness

    /// A repo whose `origin` is `ssh://fake.invalid/<source>`, a folder with one commit the repo does not have.
    static func makeRepoWithSSHRemote(_ sandbox: Sandbox) async throws -> URL {
        let source = try await sandbox.makeRepo("source")
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "remote only"], in: source)
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["remote", "add", "origin", "ssh://fake.invalid" + source.path], in: repo)
        return repo
    }

    /// For the control, a fresh repo from `build` runs the marker on `git fetch --all` with the plain (write)
    /// environment. Then a fresh repo fetches with the background fetch environment: no marker, and if
    /// `fetchSucceeds`, exit 0 with `origin/main` fetched (else any exit code). PATH starts with a fake bin
    /// folder: `ssh` runs the remote's `git-upload-pack` command locally, `git-remote-evil` is the marker script.
    func expectFetchRunsNothing(
        fetchSucceeds: Bool, build: @Sendable (Sandbox) async throws -> URL
    ) async throws {
        for control in [true, false] {
            let sandbox = try await Sandbox()
            defer { sandbox.remove() }
            let fakeBin = sandbox.root.appending(path: "fakebin")
            try Fixtures.writeScript(
                #"for last; do :; done; exec /bin/sh -c "/usr/bin/git ${last#git-}""#,
                to: fakeBin.appending(path: "ssh"))
            try Fixtures.writeScript(
                "touch '\(sandbox.marker.path)'\nexit 1", to: fakeBin.appending(path: "git-remote-evil"))
            var base = sandbox.base
            base["PATH"] = fakeBin.path + ":" + (base["PATH"] ?? "")
            let repo = try await build(sandbox)
            #expect(!sandbox.markerExists, "the setup itself ran the marker")

            let env = control
                ? GitInvocation.environment(profile: GitInvocationTests.profile, base: base)
                : try await GitInvocation.backgroundFetchEnvironment(
                    profile: GitInvocationTests.profile, base: base, runner: sandbox.runner, cwd: repo)
            let result = try await sandbox.runner.run(
                Self.fetch, cwd: repo, env: env, timeout: .seconds(30), allowedExitCodes: Set(0...255))
            if control {
                #expect(sandbox.markerExists, "positive control: the fetch must run the marker (\(result.stderrTail))")
                continue
            }
            #expect(!sandbox.markerExists, "the background fetch ran the marker")
            if fetchSucceeds {
                #expect(result.exitCode == 0, "the background fetch failed: \(result.stderrTail)")
                let fetched = try await sandbox.runner.run(
                    ["rev-parse", "--verify", "-q", "refs/remotes/origin/main"], cwd: repo, env: sandbox.base,
                    allowedExitCodes: [0, 1])
                #expect(fetched.exitCode == 0, "origin/main was not fetched")
            } else {
                #expect(result.exitCode != 0, "the blocked remote fetched")
            }
        }
    }
}
