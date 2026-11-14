// Security tests for the GitHub token on user-initiated network commands: the gate
// (`GitInvocation.networkToken`) gives it only to commands whose every URL is `https://<profile host>/…` in a
// repo without network config of its own, and then nothing the repo configures but the pre-push hook runs with
// `HISTQ_GIT_TOKEN`. Each marker case first proves, with the naive token environment (the write environment plus
// the token and its helper for every child, as before the gate), that its marker does see the token. No case
// touches the network or the Keychain: `https://git.histq.invalid/<path>` reaches the local folder `<path>`
// through a fake `git-remote-https` in a copy of git's exec path, and HOME and the global config are temporary.
import Foundation
import HistqCore
import Testing

struct NetworkTokenTests {
    static let token = GitInvocationTests.token
    static let host = GitInvocationTests.tokenHost
    static let profile = GitInvocationTests.tokenProfile

    // MARK: - URL rules

    @Test(
        "only https://<profile host>/… gets the token: no other host, scheme, port or userinfo",
        arguments: [
            ("https://git.histq.invalid/octo/repo.git", true),
            ("https://GIT.histq.invalid/octo/repo", true),
            ("https://git.histq.invalid", false),
            ("http://git.histq.invalid/octo/repo", false),
            ("HTTPS://git.histq.invalid/octo/repo", false),
            ("https://user@git.histq.invalid/octo/repo", false),
            ("https://user:pw@git.histq.invalid/octo/repo", false),
            ("https://git.histq.invalid:8443/octo/repo", false),
            ("https://git.histq.invalid./octo/repo", false),
            ("https://git.histq.invalid.evil.invalid/octo/repo", false),
            ("https://evil.invalid/git.histq.invalid/octo/repo", false),
            ("https://git.histq.invalid%2f@evil.invalid/x", false),
            ("https://git.histq.invalid?@evil.invalid/x", false),
            ("https://git.histq.invalid#@evil.invalid/x", false),
            (#"https://git.histq.invalid\@evil.invalid/x"#, false),
            ("https://git.histq.invalid/octo/re po", false),
            ("ssh://git.histq.invalid/octo/repo", false),
            ("git@git.histq.invalid:octo/repo", false),
            ("ext::sh -c touch% /tmp/x", false),
            ("file:///tmp/repo", false),
            ("/tmp/repo", false),
            ("", false),
        ])
    func urlRules(url: String, expected: Bool) {
        #expect(GitInvocation.isTokenURL(url, host: Self.host) == expected)
    }

    @Test("a profile host with a port only matches that port")
    func urlRulesWithPort() {
        let host = "ghe.histq.invalid:8443"
        #expect(GitInvocation.isTokenURL("https://ghe.histq.invalid:8443/o/r", host: host))
        #expect(!GitInvocation.isTokenURL("https://ghe.histq.invalid/o/r", host: host))
        #expect(!GitInvocation.isTokenURL("https://ghe.histq.invalid:443/o/r", host: host))
    }

    // MARK: - Gate decisions

    @Test("the gate resolves insteadOf, pushInsteadOf and pushurl, and runs no transport")
    func gateFollowsRewrites() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let repo = try await box.sandbox.makeRepo("repo")
        try await box.sandbox.git(["remote", "add", "origin", box.url(repo)], in: repo)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .attach)
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .attach)
        #expect(!box.transportRan, "the gate ran the transport")

        // The user's global rewrites: to another host for fetch and push, then for push only.
        try box.writeGlobal("[url \"https://evil.histq.invalid/\"]\n\tinsteadOf = https://\(Self.host)/\n")
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .otherURL)
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .otherURL)
        try box.writeGlobal("[url \"https://evil.histq.invalid/\"]\n\tpushInsteadOf = https://\(Self.host)/\n")
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .attach)
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .otherURL)
        // A rewrite that lands on the profile's host qualifies.
        try box.writeGlobal("[url \"https://\(Self.host)/\"]\n\tinsteadOf = gh:\n")
        try await box.sandbox.git(["remote", "add", "short", "gh:octo/repo"], in: repo)
        #expect(await box.decision(.fetch(remotes: ["origin", "short"]), in: repo) == .attach)

        try await box.sandbox.git(["config", "remote.origin.pushurl", "ssh://\(Self.host)/octo/repo"], in: repo)
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .otherURL)
        try await box.sandbox.git(["config", "--add", "remote.short.url", "http://\(Self.host)/octo/repo"], in: repo)
        #expect(await box.decision(.fetch(remotes: ["short"]), in: repo) == .otherURL)
        #expect(await box.decision(.fetch(remotes: ["nosuch"]), in: repo) == .lookupFailed)
        #expect(await box.decision(.fetch(remotes: []), in: repo) == .otherURL)
        #expect(!box.transportRan, "the gate ran the transport")

        var noAccount = Self.profile
        noAccount.github = nil
        #expect(await GitInvocation.networkToken(
            for: .fetch(remotes: ["origin"]), profile: noAccount, token: Self.token, base: box.base,
            runner: box.sandbox.runner, cwd: repo) == .noToken)
        #expect(await GitInvocation.networkToken(
            for: .fetch(remotes: ["origin"]), profile: Self.profile, token: nil, base: box.base,
            runner: box.sandbox.runner, cwd: repo) == .noToken)
    }

    @Test(
        "a repo that sets its own network config does not get the token",
        arguments: [
            ("http.proxy", "http://127.0.0.1:1", "http.proxy"),
            ("http.sslVerify", "false", "http.sslverify"),
            ("http.https://git.histq.invalid.sslVerify", "false", "http.https://git.histq.invalid.sslverify"),
            ("http.sslCAInfo", "/tmp/evil.pem", "http.sslcainfo"),
            ("http.curloptResolve", "git.histq.invalid:443:127.0.0.1", "http.curloptresolve"),
            ("http.extraHeader", "X: y", "http.extraheader"),
            ("remote.origin.proxy", "http://127.0.0.1:1", "remote.origin.proxy"),
            ("url.https://evil.invalid/.insteadOf", "nothing:", "url.https://evil.invalid/.insteadof"),
            ("url.https://evil.invalid/.pushInsteadOf", "nothing:", "url.https://evil.invalid/.pushinsteadof"),
            ("credential.helper", "!true", "credential.helper"),
            ("credential.https://other.histq.invalid.helper", "!true", "credential.https://other.histq.invalid.helper"),
            ("credential.username", "someone", "credential.username"),
        ])
    func repoNetworkConfigWithholdsToken(key: String, value: String, expected: String) async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let repo = try await box.sandbox.makeRepo("repo")
        try await box.sandbox.git(["remote", "add", "origin", box.url(repo)], in: repo)
        try await box.sandbox.git(["config", key, value], in: repo)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .repoNetworkConfig(keys: [expected]))
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .repoNetworkConfig(keys: [expected]))
    }

    @Test("a file the repo includes counts as the repo's own config; the user's global network config does not")
    func includedAndGlobalNetworkConfig() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let repo = try await box.sandbox.makeRepo("repo")
        try await box.sandbox.git(["remote", "add", "origin", box.url(repo)], in: repo)
        try box.writeGlobal("""
            [http]
            \tproxy = http://127.0.0.1:1
            [credential]
            \thelper = !true
            [url "https://elsewhere.histq.invalid/"]
            \tinsteadOf = elsewhere:

            """)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .attach)
        let included = box.sandbox.root.appending(path: "included.config")
        try Data("[http]\n\tsslVerify\n".utf8).write(to: included)
        try await box.sandbox.git(["config", "include.path", included.path], in: repo)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo)
            == .repoNetworkConfig(keys: ["http.sslverify"]))
    }

    // MARK: - Fetch

    @Test("a manual fetch with the token runs no hook: the reference-transaction hook never sees it")
    func fetchHookNeverSeesToken() async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox()
            defer { box.remove() }
            let (repo, _) = try await box.makeRepoWithRemote()
            try box.writeMarker("rt", to: repo.appending(path: ".git/hooks/reference-transaction"))
            try await box.operations(naive: naive, in: repo).fetchAll()
            #expect(box.transportGotToken, "the fetch did not sign in with the token (naive: \(naive))")
            #expect(try await box.hasRef("refs/remotes/origin/main", in: repo))
            if naive {
                #expect(box.sawToken("rt"), "positive control: the hook sees the token in the naive environment")
            } else {
                #expect(!box.sawToken("rt"), "the reference-transaction hook saw the token")
            }
        }
    }

    @Test("a repo's http.proxy keeps the token back: the fetch runs with the user's helper and its hook sees no token")
    func repoProxyFetchRunsWithoutToken() async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox(userHelper: true)
            defer { box.remove() }
            let (repo, _) = try await box.makeRepoWithRemote()
            // The fake transport ignores the proxy: only the decision matters here.
            try await box.sandbox.git(["config", "http.proxy", "http://127.0.0.1:1"], in: repo)
            try box.writeMarker("rt", to: repo.appending(path: ".git/hooks/reference-transaction"))
            try await box.operations(naive: naive, in: repo).fetchAll()
            #expect(box.ran("rt"), "the hook ran (naive: \(naive))")
            if naive {
                #expect(box.sawToken("rt"), "positive control: the hook sees the token in the naive environment")
            } else {
                #expect(!box.sawToken("rt"), "the hook saw the token")
                #expect(!box.transportGotToken, "the transport got the token")
                #expect(box.transportGotUserSecret, "the user's own helper answered")
            }
        }
    }

    @Test("a fetch that fails to sign in after the repo's config kept the token back says why")
    func withheldTokenAuthFailureSaysWhy() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, _) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["config", "http.proxy", "http://127.0.0.1:1"], in: repo)
        await #expect {
            try await box.operations(naive: false, in: repo).fetchAll()
        } throws: { error in
            guard let withheld = error as? NetworkTokenWithheld, case .auth = withheld.error else { return false }
            return withheld.reason == .repoNetworkConfig(keys: ["http.proxy"])
        }
        // Without repo config, a failed sign-in stays git's own error.
        let other = try await box.sandbox.makeRepo("other")
        try await box.sandbox.git(["remote", "add", "origin", "https://other.histq.invalid\(repo.path)"], in: other)
        await #expect {
            try await box.operations(naive: false, in: other).fetchAll()
        } throws: { error in
            if case GitError.auth = error { return true }
            return false
        }
    }

    @Test("a repo's credential helper for another host never sees the token")
    func repoHelperForAnotherHostNeverSeesToken() async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox()
            defer { box.remove() }
            let (repo, _) = try await box.makeRepoWithRemote()
            let helper = box.sandbox.root.appending(path: "bin/helper.sh")
            try box.writeMarker("helper", to: helper)
            try await box.sandbox.git(
                ["config", "credential.https://other.histq.invalid.helper", "!'\(helper.path)'"], in: repo)
            // The fake transport asks for other.histq.invalid too, as a redirect would.
            _ = try? await box.operations(naive: naive, in: repo).fetchAll()
            #expect(box.ran("helper"), "the helper ran (naive: \(naive))")
            #expect(box.sawToken("helper") == naive, "the helper saw the token: \(box.sawToken("helper")) (naive: \(naive))")
        }
    }

    @Test(
        "an ext, file or remote-helper transport never runs with the token",
        arguments: ["ext", "file", "vcs"])
    func otherTransportsNeverSeeToken(transport: String) async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox()
            defer { box.remove() }
            let repo = try await box.sandbox.makeRepo("repo")
            let source = try await box.sandbox.makeRepo("source")
            let marker = box.fakeBin.appending(path: "git-remote-evil")
            try box.writeMarker("transport", to: marker)
            let config: [(String, String)] = switch transport {
            case "ext": [("remote.origin.url", "ext::\(marker.path)"), ("protocol.ext.allow", "always")]
            case "file":
                [("remote.origin.url", "file://" + source.path), ("remote.origin.uploadpack", marker.path),
                 ("protocol.file.allow", "always")]
            // An https URL on the profile's host passes the gate; the helper it names must still not run.
            default: [("remote.origin.url", box.url(source)), ("remote.origin.vcs", "evil")]
            }
            for (key, value) in config {
                try await box.sandbox.git(["config", key, value], in: repo)
            }
            _ = try? await box.operations(naive: naive, in: repo).fetchAll()
            if naive {
                #expect(box.sawToken("transport"), "positive control: the \(transport) transport sees the token")
            } else {
                #expect(!box.sawToken("transport"), "the \(transport) transport saw the token")
            }
        }
    }

    @Test("fetch --all with a remote on another host gets no token; with every remote on the profile's host, it does")
    func fetchAllIsAllOrNothing() async throws {
        let box = try await TokenSandbox(userHelper: true)
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["remote", "add", "mirror", box.url(source)], in: repo)
        try await box.operations(naive: false, in: repo).fetchAll()
        #expect(box.transportGotToken)

        try box.clearTransport()
        try await box.sandbox.git(["remote", "add", "local", source.path], in: repo)
        try await box.operations(naive: false, in: repo).fetchAll()
        #expect(box.transportRan)
        #expect(!box.transportGotToken, "a fetch --all that also reaches a local folder got the token")
        #expect(box.transportGotUserSecret)
    }

    // MARK: - Fetch refspec

    @Test("fetchRefspec fetches a pull request's head into pr/<n> through the gate: the transport gets the token, no hook")
    func fetchRefspecGoesThroughGate() async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox()
            defer { box.remove() }
            let (repo, source) = try await box.makeRepoWithRemote()
            try await box.sandbox.git(["update-ref", "refs/pull/1/head", "HEAD"], in: source)
            try box.writeMarker("rt", to: repo.appending(path: ".git/hooks/reference-transaction"))
            try await box.operations(naive: naive, in: repo).fetchRefspec(remote: "origin", refspec: "pull/1/head:pr/1")
            #expect(box.transportGotToken, "the fetch did not sign in with the token (naive: \(naive))")
            #expect(try await box.hasRef("refs/heads/pr/1", in: repo))
            if naive {
                #expect(box.sawToken("rt"), "positive control: the hook sees the token in the naive environment")
            } else {
                #expect(!box.sawToken("rt"), "the reference-transaction hook saw the token")
            }
        }
    }

    @Test("fetchRefspec refuses a forced, option-like, pattern or malformed refspec, a bad branch and a non-remote")
    func fetchRefspecRefusesInjection() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["update-ref", "refs/pull/1/head", "HEAD"], in: source)
        let ops = box.operations(naive: false, in: repo)
        let cases: [(remote: String, refspec: String, error: GitOperationError)] = [
            ("origin", "+pull/1/head:pr/1", .invalidRefspec("+pull/1/head:pr/1")),
            ("origin", "pull/1/head:+pr/1", .invalidRefspec("pull/1/head:+pr/1")),
            ("origin", "--upload-pack=touch x:pr/1", .invalidRefspec("--upload-pack=touch x:pr/1")),
            ("origin", "pull/1/head", .invalidRefspec("pull/1/head")),
            ("origin", ":pr/1", .invalidRefspec(":pr/1")),
            ("origin", "a:b:c", .invalidRefspec("a:b:c")),
            ("origin", "pull/*/head:pr/1", .invalidRefspec("pull/*/head:pr/1")),
            ("origin", "pull/1/head:pr/1 x", .invalidRefspec("pull/1/head:pr/1 x")),
            ("origin", "pull/1/head:-pr", .invalidBranchName("-pr")),
            ("origin", "pull/1/head:pr/1..2", .invalidBranchName("pr/1..2")),
            ("--upload-pack=touch x", "pull/1/head:pr/1", .invalidRemoteName("--upload-pack=touch x")),
            ("-o", "pull/1/head:pr/1", .invalidRemoteName("-o")),
            (box.url(source), "pull/1/head:pr/1", .invalidRemoteName(box.url(source))),
        ]
        for item in cases {
            await #expect(throws: item.error, "\(item.remote) \(item.refspec)") {
                try await ops.fetchRefspec(remote: item.remote, refspec: item.refspec)
            }
        }
        #expect(!box.transportRan, "a refused fetch still contacted the remote")
        #expect(!(try await box.hasRef("refs/heads/pr/1", in: repo)))
        // Positive control: the same fetch with a valid refspec runs.
        try await ops.fetchRefspec(remote: "origin", refspec: "pull/1/head:pr/1")
        #expect(box.transportRan)
        #expect(try await box.hasRef("refs/heads/pr/1", in: repo))
    }

    // MARK: - Pull

    @Test(
        "a pull fetches with the token, then merges or rebases without it: the merge's hooks never see it",
        arguments: [GitOperations.PullMode.fastForward, .fastForwardOnly, .rebase])
    func pullMergeHalfRunsWithoutToken(mode: GitOperations.PullMode) async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox()
            defer { box.remove() }
            let (repo, source) = try await box.makeRepoWithRemote()
            try await box.sandbox.git(["fetch", "-q", "origin"], in: repo, env: box.naiveEnvironment())
            try await box.sandbox.git(["branch", "-q", "--set-upstream-to=origin/main", "main"], in: repo)
            try await box.sandbox.git(["reset", "-q", "--hard", "origin/main"], in: repo)
            try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "remote two"], in: source)
            if mode == .fastForward {
                // A local commit too, so the pull makes a merge commit.
                try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "local"], in: repo)
            }
            try box.clearTransport()
            try box.writeMarker("rt", to: repo.appending(path: ".git/hooks/reference-transaction"))
            try box.writeMarker("post-merge", to: repo.appending(path: ".git/hooks/post-merge"))

            try await box.operations(naive: naive, in: repo).pull(mode)

            #expect(box.transportGotToken, "the pull's fetch did not sign in with the token (naive: \(naive))")
            let upstream = try await box.sandbox.git(["rev-parse", "origin/main"], in: repo)
            let merged = try await box.sandbox.git(["merge-base", "--is-ancestor", upstream, "HEAD"], in: repo)
            #expect(merged.isEmpty, "HEAD has the upstream")
            if mode == .fastForward {
                let subject = try await box.sandbox.git(["log", "-1", "--format=%s"], in: repo)
                #expect(subject.hasPrefix("Merge branch 'main' of https://\(Self.host)/"), "\(subject)")
                #expect(box.ran("post-merge"), "the post-merge hook ran (naive: \(naive))")
            }
            #expect(box.ran("rt"), "the reference-transaction hook ran (naive: \(naive))")
            if naive {
                #expect(box.sawToken("rt"), "positive control: the merge's hooks see the token in the naive environment")
            } else {
                #expect(!box.sawToken("rt") && !box.sawToken("post-merge"), "a merge hook saw the token")
            }
        }
    }

    @Test(
        "a split pull fails as git pull does when the upstream branch is gone from the remote",
        arguments: [GitOperations.PullMode.fastForward, .fastForwardOnly, .rebase])
    func splitPullFailsWithoutUpstream(mode: GitOperations.PullMode) async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["branch", "feature"], in: source)
        try await box.sandbox.git(["fetch", "-q", "origin"], in: repo, env: box.naiveEnvironment())
        try await box.sandbox.git(["checkout", "-q", "-b", "feature", "--track", "origin/feature"], in: repo)
        try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "local"], in: repo)
        try await box.sandbox.git(["branch", "-q", "-D", "feature"], in: source)
        let before = try await box.sandbox.git(["rev-parse", "HEAD"], in: repo)

        await #expect(throws: GitError.self) { try await box.operations(naive: false, in: repo).pull(mode) }
        #expect(box.transportGotToken, "the split ran (its fetch signed in with the token)")
        #expect(try await box.sandbox.git(["rev-parse", "HEAD"], in: repo) == before)
    }

    @Test(
        "a split pull --rebase rebases onto the fetched commit from its fork point, as git pull --rebase does",
        arguments: ["noTrackingRef", "rewrittenTrackingRef"])
    func splitRebaseMatchesPull(scenario: String) async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let naive = box.naiveEnvironment()
        let (repo, source) = try await box.makeRepoWithRemote()
        // A pull request ref outside the default refspec, as `gh pr checkout` leaves for a fork's branch.
        try Data("a\n".utf8).write(to: source.appending(path: "pr.txt"))
        try await box.sandbox.git(["add", "pr.txt"], in: source)
        try await box.sandbox.git(["commit", "-q", "-m", "pr one"], in: source)
        let first = try await box.sandbox.git(["rev-parse", "HEAD"], in: source)
        try await box.sandbox.git(["update-ref", "refs/pull/1/head", first], in: source)
        if scenario == "rewrittenTrackingRef" {
            // Mapped to a tracking ref, so `@{upstream}` and its fork point exist.
            try await box.sandbox.git(
                ["config", "--add", "remote.origin.fetch", "+refs/pull/*/head:refs/remotes/origin/pr/*"], in: repo)
        }
        try await box.sandbox.git(["fetch", "-q", "origin", "refs/pull/1/head"], in: repo, env: naive)
        if scenario == "rewrittenTrackingRef" {
            try await box.sandbox.git(["fetch", "-q", "origin"], in: repo, env: naive)
        }
        try await box.sandbox.git(["checkout", "-q", "-b", "feature", "FETCH_HEAD"], in: repo)
        try await box.sandbox.git(["config", "branch.feature.remote", "origin"], in: repo)
        try await box.sandbox.git(["config", "branch.feature.merge", "refs/pull/1/head"], in: repo)
        try Data("local\n".utf8).write(to: repo.appending(path: "local.txt"))
        try await box.sandbox.git(["add", "local.txt"], in: repo)
        try await box.sandbox.git(["commit", "-q", "-m", "local"], in: repo)
        // The remote moves the pull request: rewritten (the fork point drops "pr one") or one commit further.
        if scenario == "rewrittenTrackingRef" {
            try await box.sandbox.git(["reset", "-q", "--hard", "HEAD^"], in: source)
            try Data("a2\n".utf8).write(to: source.appending(path: "pr.txt"))
            try await box.sandbox.git(["add", "pr.txt"], in: source)
            try await box.sandbox.git(["commit", "-q", "-m", "pr one, rewritten"], in: source)
        } else {
            try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "pr two"], in: source)
        }
        let moved = try await box.sandbox.git(["rev-parse", "HEAD"], in: source)
        try await box.sandbox.git(["update-ref", "refs/pull/1/head", moved], in: source)
        let copy = box.sandbox.root.appending(path: "repo-naive", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: repo, to: copy)

        try await box.operations(naive: true, in: copy).pull(.rebase)
        try await box.operations(naive: false, in: repo).pull(.rebase)

        let history = { (folder: URL) in
            try await box.sandbox.git(["log", "--format=%s %T", "-n", "4"], in: folder)
        }
        let expected = try await history(copy)
        #expect(try await history(repo) == expected)
        #expect(expected.hasPrefix("local "), "\(expected)")
        #expect(try await box.sandbox.git(["rev-parse", "HEAD^"], in: repo) == moved)
        #expect(box.transportGotToken, "the split ran (its fetch signed in with the token)")
    }

    // MARK: - Submodules

    @Test(
        "with submodules and recursion on, a command gets no token; recursion off or no submodules keeps it",
        arguments: [
            ("submodule.recurse", "true", true, ["submodule.recurse"]),
            ("fetch.recurseSubmodules", "on-demand", true, ["fetch.recursesubmodules"]),
            ("push.recurseSubmodules", "check", true, ["push.recursesubmodules"]),
            ("submodule.recurse", "false", true, []),
            ("push.recurseSubmodules", "no", true, []),
            ("submodule.recurse", "true", false, []),
        ])
    func submoduleRecursionWithholdsToken(key: String, value: String, submodules: Bool, expected: [String])
        async throws
    {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let repo = try await box.sandbox.makeRepo("repo")
        try await box.sandbox.git(["remote", "add", "origin", box.url(repo)], in: repo)
        if submodules {
            try Data("[submodule \"lib\"]\n\tpath = lib\n\turl = ../lib\n".utf8)
                .write(to: repo.appending(path: ".gitmodules"))
        }
        // The user's own config.
        try box.writeGlobal("[\(key.split(separator: ".")[0])]\n\t\(key.split(separator: ".")[1]) = \(value)\n")
        let decision: GitInvocation.TokenDecision = expected.isEmpty ? .attach : .submoduleRecursion(keys: expected)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == decision)
        #expect(await box.decision(.push(remote: "origin"), in: repo) == decision)
    }

    @Test("a submodule entry in the repo's config counts as submodules, and a failed sign-in then says why")
    func submoduleRecursionAuthFailureSaysWhy() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, _) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["config", "submodule.lib.active", "true"], in: repo)
        try box.writeGlobal("[submodule]\n\trecurse = true\n")
        await #expect {
            try await box.operations(naive: false, in: repo).fetchAll()
        } throws: { error in
            guard let withheld = error as? NetworkTokenWithheld, case .auth = withheld.error else { return false }
            return withheld.reason == .submoduleRecursion(keys: ["submodule.recurse"])
        }
        #expect(box.transportRan && !box.transportGotToken)
    }

    // MARK: - Push

    @Test(
        "a push with the token runs the repo's own pre-push hook without it, and no other hook",
        arguments: ["file", "symlink"])
    func pushHooksNeverSeeToken(hookKind: String) async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox()
            defer { box.remove() }
            let (repo, source) = try await box.makeRepoWithRemote()
            try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "to push"], in: repo)
            // The custom hook records its arguments, its input, whether it sees the variable, and what a
            // `git credential fill` for the profile's host gives it.
            let root = box.sandbox.root.path
            let custom = box.sandbox.root.appending(path: "hooks-src/custom-pre-push")
            try Fixtures.writeScript("""
                echo "$*" >> '\(root)/pre-push.ran'
                cat > '\(root)/pre-push.stdin'
                test -n "$HISTQ_GIT_TOKEN" && touch '\(root)/pre-push.token'
                printf 'protocol=https\\nhost=\(Self.host)\\n\\n' | git credential fill > '\(root)/pre-push.fill' 2>/dev/null
                echo "${GIT_ALLOW_PROTOCOL-unset} ${GIT_ASKPASS-unset} ${SSH_ASKPASS-unset}" > '\(root)/pre-push.env'
                git config --get core.hooksPath > '\(root)/pre-push.hookspath'
                exit 0
                """, to: custom)
            let hook = repo.appending(path: ".git/hooks/pre-push")
            if hookKind == "symlink" {
                try FileManager.default.createSymbolicLink(at: hook, withDestinationURL: custom)
            } else {
                try FileManager.default.copyItem(at: custom, to: hook)
            }
            try box.writeMarker("rt", to: repo.appending(path: ".git/hooks/reference-transaction"))

            try await box.operations(naive: naive, in: repo).push(branch: "main", to: "origin", as: "pushed")

            #expect(box.transportGotToken, "the push did not sign in with the token (naive: \(naive))")
            let pushed = try await box.sandbox.git(["rev-parse", "pushed"], in: source)
            let local = try await box.sandbox.git(["rev-parse", "main"], in: repo)
            #expect(pushed == local, "the push landed (naive: \(naive))")
            // The wrapper hands git's arguments and input on: the remote's name and URL, then the refs.
            #expect(box.firstArguments("pre-push") == "origin", "the pre-push hook ran (naive: \(naive))")
            let input = (try? String(contentsOfFile: "\(root)/pre-push.stdin", encoding: .utf8)) ?? ""
            #expect(input.hasPrefix("refs/heads/main \(local) refs/heads/pushed "), "\(input)")
            let fill = (try? String(contentsOfFile: "\(root)/pre-push.fill", encoding: .utf8)) ?? ""
            if naive {
                #expect(box.sawToken("pre-push") && fill.contains(Self.token),
                        "positive control: the hook sees the token in the naive environment")
                #expect(box.sawToken("rt"), "positive control: reference-transaction sees the token")
            } else {
                #expect(!box.sawToken("pre-push"), "the pre-push hook saw HISTQ_GIT_TOKEN")
                #expect(!fill.contains(Self.token), "git credential fill in the pre-push hook gave the token")
                #expect(!box.ran("rt"), "the reference-transaction hook ran during a token-carrying push")
                // The hook sees what it would without the token: the base has no protocol list or askpass, and
                // a `git` in it reads the repo's hooks folder, not the wrapper's.
                let env = (try? String(contentsOfFile: "\(root)/pre-push.env", encoding: .utf8)) ?? ""
                #expect(env == "unset unset unset\n", "\(env)")
                let hooksPath = (try? String(contentsOfFile: "\(root)/pre-push.hookspath", encoding: .utf8)) ?? "?"
                #expect(hooksPath.isEmpty, "the hook's git sees core.hooksPath \(hooksPath)")
            }
        }
    }

    @Test(
        "git-lfs's generated pre-push stub gets the token for git-lfs; a repo-named transfer agent withholds it",
        arguments: ["3.x", "2.x", "1.x-minimal", "symlink", "customTransfer"])
    func lfsStubGetsToken(variant: String) async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "to push"], in: repo)
        // A fake git-lfs on PATH: records its arguments, whether it sees the variable, and what
        // `git credential fill` gives it, as git-lfs asks before an upload.
        let root = box.sandbox.root.path
        try Fixtures.writeScript("""
            echo "$*" >> '\(root)/lfs.ran'
            test -n "$HISTQ_GIT_TOKEN" && touch '\(root)/lfs.token'
            printf 'protocol=https\\nhost=\(Self.host)\\n\\n' | git credential fill > '\(root)/lfs.fill' 2>/dev/null
            exit 0
            """, to: box.fakeBin.appending(path: "git-lfs"))
        let stub = variant == "2.x" ? Self.lfsStub2 : variant == "1.x-minimal" ? Self.lfsStubMinimal : Self.lfsStub3
        let hook = repo.appending(path: ".git/hooks/pre-push")
        if variant == "symlink" {
            let target = box.sandbox.root.appending(path: "hooks-src/pre-push")
            try Fixtures.writeScript(stub, to: target)
            try FileManager.default.createSymbolicLink(at: hook, withDestinationURL: target)
        } else {
            try Fixtures.writeScript(stub, to: hook)
        }
        if variant == "customTransfer" {
            try await box.sandbox.git(["config", "lfs.customtransfer.evil.path", "/usr/bin/true"], in: repo)
        }

        try await box.operations(naive: false, in: repo).push(branch: "main", to: "origin", as: "pushed")

        #expect(try await box.sandbox.git(["rev-parse", "pushed"], in: source)
            == box.sandbox.git(["rev-parse", "main"], in: repo))
        #expect(box.firstArguments("lfs") == "pre-push", "git-lfs ran from the stub")
        let fill = (try? String(contentsOfFile: "\(root)/lfs.fill", encoding: .utf8)) ?? ""
        if variant == "customTransfer" {
            #expect(!box.sawToken("lfs") && !fill.contains(Self.token), "git-lfs got the token")
        } else {
            #expect(box.sawToken("lfs") && fill.contains("password=\(Self.token)\n"), "git-lfs did not get the token")
        }
    }

    /// git-lfs 3.x writes this (the message is translated in some locales); 1.x and 2.x used `echo`.
    static let lfsStub3 = #"""
        command -v git-lfs >/dev/null 2>&1 || { printf >&2 "\n%s\n\n" "This repository is configured for Git LFS but 'git-lfs' was not found on your path. If you no longer wish to use Git LFS, remove this hook by deleting the 'pre-push' file in the hooks directory (set by 'core.hookspath'; usually '.git/hooks')."; exit 2; }
        git lfs pre-push "$@"
        """#
    static let lfsStub2 = #"""
        command -v git-lfs >/dev/null 2>&1 || { echo >&2 "\nThis repository is configured for Git LFS but 'git-lfs' was not found on your path. If you no longer wish to use Git LFS, remove this hook by deleting .git/hooks/pre-push.\n"; exit 2; }
        git lfs pre-push "$@"
        """#
    static let lfsStubMinimal = #"git lfs pre-push "$@""#

    @Test("the git-lfs stub rule: exact lines only, and a message the shell expands nothing in")
    func lfsStubRule() {
        let accepted = [
            "#!/bin/sh\n" + Self.lfsStub3 + "\n",
            "#!/bin/sh\n" + Self.lfsStub2 + "\n",
            "#!/bin/sh\n" + Self.lfsStubMinimal + "\n",
            "#!/bin/sh\n# a comment\n\n  " + Self.lfsStub3.replacing("\n", with: "\n\t") + "  \n\n",
            Self.lfsStub3.replacing("Git LFS but", with: "Git LFS mais"),
        ]
        for text in accepted {
            #expect(GitInvocation.isLFSPrePushStub(text), "\(text)")
        }
        let rejected = [
            "",
            "#!/bin/sh\n",
            Self.lfsStub3 + "\ntouch /tmp/x",
            "touch /tmp/x\n" + Self.lfsStub3,
            Self.lfsStub3.replacing(#""$@""#, with: #""$@"; touch /tmp/x"#),
            Self.lfsStub3.replacing(#""$@""#, with: #""$@" && touch /tmp/x"#),
            Self.lfsStub3.replacing("Git LFS but", with: "$(touch /tmp/x)"),
            Self.lfsStub3.replacing("Git LFS but", with: "`touch /tmp/x`"),
            Self.lfsStub3.replacing("Git LFS but", with: #"\" ; touch /tmp/x ; echo \""#),
            Self.lfsStub3.replacing("Git LFS but", with: #"" ; touch /tmp/x ; echo ""#),
            Self.lfsStub3.replacing("exit 2; }", with: "exit 2; }; touch /tmp/x"),
            Self.lfsStub3.replacing("command -v git-lfs", with: "command -v evil"),
            Self.lfsStub3.replacing("git lfs pre-push", with: "git lfs post-checkout"),
            Self.lfsStubMinimal + "\n" + Self.lfsStubMinimal,
            Self.lfsStub2.replacing("\\nThis", with: "This"),
        ]
        for text in rejected {
            #expect(!GitInvocation.isLFSPrePushStub(text), "\(text)")
        }
    }

    @Test("a push to a pushInsteadOf rewrite on another host does not get the token")
    func pushRewriteGetsNoToken() async throws {
        let box = try await TokenSandbox(userHelper: true)
        defer { box.remove() }
        let (repo, _) = try await box.makeRepoWithRemote()
        try box.writeGlobal("""
            [credential]
            \thelper =
            \thelper = \(box.userHelper)
            [url "https://other.histq.invalid/"]
            \tpushInsteadOf = https://\(Self.host)/

            """)
        try box.writeMarker("pre-push", to: repo.appending(path: ".git/hooks/pre-push"))
        try await box.operations(naive: false, in: repo).push(branch: "main", to: "origin", as: "copy")
        #expect(box.transportRan)
        #expect(!box.transportGotToken)
        #expect(box.ran("pre-push") && !box.sawToken("pre-push"))
    }

    // MARK: - Clone

    @Test("a clone gets the token only for an https URL on the profile's host, after the user's rewrites")
    func cloneGate() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let source = try await box.sandbox.makeRepo("source")
        let env = { (url: String) in
            await GitInvocation.cloneEnvironment(
                url: url, profile: Self.profile, base: box.base, token: Self.token, runner: box.sandbox.runner)
        }
        let good = await env(box.url(source))
        #expect(good["HISTQ_GIT_TOKEN"] == Self.token)
        #expect(good["GIT_ALLOW_PROTOCOL"] == "https")
        for url in ["https://other.histq.invalid/o/r", "http://\(Self.host)/o/r", "https://me@\(Self.host)/o/r",
                    "ssh://\(Self.host)/o/r", source.path] {
            #expect(await env(url)["HISTQ_GIT_TOKEN"] == nil, "\(url)")
        }
        try box.writeGlobal("[url \"https://other.histq.invalid/\"]\n\tinsteadOf = https://\(Self.host)/\n")
        #expect(await env(box.url(source))["HISTQ_GIT_TOKEN"] == nil, "a rewrite to another host kept the token")
        try box.writeGlobal("")

        // The real clone signs in with the token through the fake transport.
        let destination = box.sandbox.root.appending(path: "clone")
        try await GitOperations.clone(
            url: box.url(source), into: destination, runner: box.sandbox.runner, env: good) { _ in }
        #expect(box.transportGotToken)
        #expect(try await box.hasRef("refs/remotes/origin/main", in: destination))
    }
}

// MARK: - Harness

/// A `Sandbox` whose git reaches `https://git.histq.invalid/<path>` as the local folder `<path>`: `GIT_EXEC_PATH` is a
/// copy of git's exec path (links) with a fake `git-remote-https`. The fake first asks `git credential fill` for its
/// own host, as git's https transport does (and keeps the answer in `transport.txt`), then for
/// `other.histq.invalid`, as after a redirect, fails like GitHub without a password, and else serves the folder with
/// `git upload-pack`/`git receive-pack`. `fakeBin` comes first on PATH.
struct TokenSandbox {
    let sandbox: Sandbox
    let base: [String: String]
    let fakeBin: URL
    /// The user's own global helper (`!'<script>'`), answering `user`/`user-secret`; set with `userHelper: true`.
    let userHelper: String
    var global: URL { sandbox.root.appending(path: "home/.gitconfig") }
    var transportFile: URL { sandbox.root.appending(path: "transport.txt") }

    init(userHelper withUserHelper: Bool = false) async throws {
        sandbox = try await Sandbox()
        let execPath = try await sandbox.git(["--exec-path"], in: sandbox.root)
        let fakeExec = sandbox.root.appending(path: "exec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fakeExec, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: execPath) where name != "git-remote-https" {
            try FileManager.default.createSymbolicLink(
                at: fakeExec.appending(path: name), withDestinationURL: URL(filePath: execPath).appending(path: name))
        }
        let out = sandbox.root.appending(path: "transport.txt").path
        try Fixtures.writeScript(#"""
            host=$(printf '%s' "$2" | cut -d/ -f3)
            dir="/${2#https://*/}"
            printf 'protocol=https\nhost=%s\n\n' "$host" | git credential fill > '\#(out)' 2>/dev/null
            printf 'protocol=https\nhost=other.histq.invalid\n\n' | git credential fill > /dev/null 2>&1
            grep -q '^password=' '\#(out)' || { echo "fatal: Authentication failed for '$2'" >&2; exit 128; }
            while read -r line; do
              case "$line" in
                capabilities) printf 'connect\n\n' ;;
                "connect git-"*) printf '\n'; exec git "${line#connect git-}" "$dir" ;;
                *) exit 0 ;;
              esac
            done
            """#, to: fakeExec.appending(path: "git-remote-https"))
        fakeBin = sandbox.root.appending(path: "fakebin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)

        let script = sandbox.root.appending(path: "bin/user-helper.sh")
        try Fixtures.writeScript(
            "test \"$1\" = get && printf 'username=user\\npassword=user-secret\\n'\nexit 0", to: script)
        userHelper = "!'\(script.path)'"
        try Data((withUserHelper ? "[credential]\n\thelper =\n\thelper = \(userHelper)\n" : "").utf8)
            .write(to: sandbox.root.appending(path: "home/.gitconfig"))
        var base = sandbox.base
        base["GIT_EXEC_PATH"] = fakeExec.path
        base["GIT_CONFIG_GLOBAL"] = sandbox.root.appending(path: "home/.gitconfig").path
        base["PATH"] = fakeBin.path + ":" + (base["PATH"] ?? "")
        self.base = base
    }

    func remove() { sandbox.remove() }

    func url(_ folder: URL) -> String { "https://\(NetworkTokenTests.host)\(folder.path)" }

    func writeGlobal(_ text: String) throws { try Data(text.utf8).write(to: global) }

    /// A repo whose `origin` is the fake https URL of `source`, a folder with a commit the repo does not have.
    func makeRepoWithRemote() async throws -> (repo: URL, source: URL) {
        let source = try await sandbox.makeRepo("source")
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "remote only"], in: source)
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["remote", "add", "origin", url(source)], in: repo)
        return (repo, source)
    }

    func decision(_ target: GitInvocation.NetworkTarget, in repo: URL) async -> GitInvocation.TokenDecision {
        await GitInvocation.networkToken(
            for: target, profile: NetworkTokenTests.profile, token: NetworkTokenTests.token, base: base,
            runner: sandbox.runner, cwd: repo)
    }

    /// The operations with the gate, or (`naive`) with the naive environment for every command.
    func operations(naive: Bool, in repo: URL) -> GitOperations {
        naive
            ? GitOperations(runner: sandbox.runner, cwd: repo, env: naiveEnvironment())
            : GitOperations(
                runner: sandbox.runner, cwd: repo, profile: NetworkTokenTests.profile, base: base,
                token: NetworkTokenTests.token)
    }

    /// Before the gate: the write environment plus `HISTQ_GIT_TOKEN` and the token helper, for every child.
    func naiveEnvironment() -> [String: String] {
        var env = GitInvocation.environment(profile: NetworkTokenTests.profile, base: base, access: .write)
        let index = Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0
        env["GIT_CONFIG_KEY_\(index)"] = GitInvocationTests.tokenHelperKey
        env["GIT_CONFIG_VALUE_\(index)"] = GitInvocation.tokenHelper
        env["GIT_CONFIG_COUNT"] = String(index + 1)
        env["HISTQ_GIT_TOKEN"] = NetworkTokenTests.token
        return env
    }

    /// A marker script: appends its arguments to `<name>.ran`, touches `<name>.token` when it sees
    /// `HISTQ_GIT_TOKEN`, prints nothing and succeeds (a hook, a credential helper or a transport).
    func writeMarker(_ name: String, to url: URL) throws {
        let ran = sandbox.root.appending(path: "\(name).ran").path
        let token = sandbox.root.appending(path: "\(name).token").path
        try Fixtures.writeScript(
            "echo \"$*\" >> '\(ran)'\ntest -n \"$HISTQ_GIT_TOKEN\" && touch '\(token)'\nexit 0", to: url)
    }

    func ran(_ name: String) -> Bool { exists("\(name).ran") }
    func sawToken(_ name: String) -> Bool { exists("\(name).token") }

    /// The first word the marker's first run got.
    func firstArguments(_ name: String) -> String? {
        let text = try? String(contentsOf: sandbox.root.appending(path: "\(name).ran"), encoding: .utf8)
        return text?.split(separator: "\n").first?.split(separator: " ").first.map(String.init)
    }

    var transportRan: Bool { FileManager.default.fileExists(atPath: transportFile.path) }
    var transportGotToken: Bool { transportAnswer.contains("password=\(NetworkTokenTests.token)\n") }
    var transportGotUserSecret: Bool { transportAnswer.contains("password=user-secret\n") }
    private var transportAnswer: String { (try? String(contentsOf: transportFile, encoding: .utf8)) ?? "" }

    func clearTransport() throws {
        if transportRan { try FileManager.default.removeItem(at: transportFile) }
    }

    func hasRef(_ ref: String, in repo: URL) async throws -> Bool {
        try await sandbox.runner.run(
            ["rev-parse", "--verify", "-q", ref], cwd: repo, env: sandbox.base, allowedExitCodes: [0, 1]).exitCode == 0
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: sandbox.root.appending(path: name).path)
    }
}

extension Sandbox {
    /// A setup command with another environment; returns its trimmed stdout.
    @discardableResult
    func git(_ args: [String], in dir: URL, env: [String: String]) async throws -> String {
        let result = try await runner.run(args, cwd: dir, env: env, timeout: .seconds(30))
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
