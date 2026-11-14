// Contract tests for the GitHub client and the device flow, served by a stub `URLProtocol` with inline JSON: no
// test reaches the network. They also guard the token: it only travels in the `Authorization` header to the API
// host, and no error or description shows it.
import Foundation
import HistqCore
import Synchronization
import Testing

struct GitHubClientTests {
    /// A made-up token; the tests look for it where it must never be.
    static let token = "ghp_HistqFakeToken0123456789"

    static func pullJSON(_ number: Int) -> String {
        """
        {"id": \(number), "number": \(number), "title": "PR \(number)", "state": "open", "draft": false,
         "html_url": "https://github.com/octo/hello/pull/\(number)",
         "user": {"id": 1, "login": "octo", "avatar_url": "https://avatars.example/u/1"},
         "head": {"label": "octo:feature", "ref": "feature", "sha": "aaaa"}, "base": {"ref": "main", "sha": "bbbb"},
         "body": "Hi", "body_html": "<p>Hi</p>", "created_at": "2026-11-01T10:00:00Z", "labels": []}
        """
    }

    // MARK: - Pagination

    @Test("a list follows Link rel=\"next\" with the token only in the Authorization header")
    func paginationFollowsNextLink() async throws {
        let stub = StubServer { request in
            let page2 = "https://api.github.com/repositories/1/pulls?state=open&per_page=100&page=2"
            if request.url?.query()?.contains("page=2") == true {
                return .init(body: "[\(Self.pullJSON(2))]")
            }
            return .init(
                headers: ["Link": "<\(page2)>; rel=\"next\", <\(page2)>; rel=\"last\""],
                body: "[\(Self.pullJSON(1))]")
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = try #require(GitHubClient.repository(fromRemoteURL: "https://github.com/octo/hello.git"))

        let pulls = try await client.pullRequests(in: repo, state: .open)

        #expect(pulls.map(\.number) == [1, 2])
        #expect(pulls.first?.bodyHTML == "<p>Hi</p>")
        let requests = stub.requests
        #expect(requests.count == 2)
        #expect(requests.first?.url?.path() == "/repos/octo/hello/pulls")
        #expect(requests.first?.url?.query()?.contains("per_page=100") == true)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
            #expect(request.url?.host() == "api.github.com")
            #expect(request.url?.absoluteString.contains(Self.token) == false)
        }
    }

    @Test("a next-page link to another host is refused, so the token never goes there")
    func paginationRefusesOtherOrigin() async throws {
        let stub = StubServer { _ in
            .init(headers: ["Link": "<https://evil.example/repos/octo/hello/pulls?page=2>; rel=\"next\""],
                  body: "[\(Self.pullJSON(1))]")
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        await #expect(throws: GitHubError.invalidResponse("a next-page link to another host")) {
            try await client.pullRequests(in: repo, state: .open)
        }
        #expect(stub.requests.allSatisfy { $0.url?.host() == "api.github.com" })
    }

    @Test("a redirect to another host is not followed (one on the API host is)", arguments: [
        ("https://api.github.com/moved", true), ("https://evil.example/user", false),
    ])
    func redirectToOtherOriginIsNotFollowed(target: String, isFollowed: Bool) async throws {
        let stub = StubServer { request in
            if request.url?.path() == "/user" {
                return .init(status: 302, headers: ["Location": target], body: "", redirect: URL(string: target))
            }
            return .init(body: #"{"id": 9, "login": "moved"}"#)
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)

        if isFollowed {
            #expect(try await client.currentUser().login == "moved", "positive control: the stub redirects")
        } else {
            await #expect(throws: GitHubError.self) { try await client.currentUser() }
            #expect(stub.requests.allSatisfy { $0.url?.host() == "api.github.com" })
        }
    }

    // MARK: - Typed errors

    struct ErrorCase: Sendable, CustomTestStringConvertible {
        var status: Int
        var headers: [String: String] = [:]
        var body: String
        var expected: GitHubError
        var testDescription: String { "\(status) \(expected)" }
    }

    @Test("HTTP failures become typed errors whose descriptions never show the token", arguments: [
        ErrorCase(status: 401, body: #"{"message": "Bad credentials"}"#, expected: .unauthorized),
        ErrorCase(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000000"],
                  body: #"{"message": "API rate limit exceeded"}"#,
                  expected: .rateLimited(resetsAt: Date(timeIntervalSince1970: 1_800_000_000))),
        ErrorCase(status: 429, headers: ["Retry-After": "60"], body: "{}",
                  expected: .secondaryRateLimited(retryAfterSeconds: 60)),
        ErrorCase(status: 403, headers: ["X-RateLimit-Remaining": "4000"],
                  body: #"{"message": "You have exceeded a secondary rate limit."}"#,
                  expected: .secondaryRateLimited(retryAfterSeconds: nil)),
        ErrorCase(status: 403, headers: ["X-RateLimit-Remaining": "4000"],
                  body: #"{"message": "Resource not accessible by integration"}"#,
                  expected: .forbidden(message: "Resource not accessible by integration")),
        ErrorCase(status: 404, body: #"{"message": "Not Found"}"#, expected: .notFound),
        ErrorCase(status: 200, body: "not json", expected: .invalidResponse("unexpected JSON for GitHubUser")),
    ])
    func httpFailuresAreTyped(_ errorCase: ErrorCase) async throws {
        let stub = StubServer { _ in .init(status: errorCase.status, headers: errorCase.headers, body: errorCase.body) }
        let client = try GitHubClient(token: Self.token, session: stub.session)

        let error = await #expect(throws: GitHubError.self) { try await client.currentUser() }
        #expect(error == errorCase.expected)
        var dumped = ""
        dump(client, to: &dumped)
        for text in [String(describing: error), String(reflecting: error), String(describing: client),
                     String(reflecting: client), dumped] {
            #expect(!text.contains(Self.token), "\(text)")
        }
    }

    // MARK: - Search

    /// One `/search/issues` item as GitHub sends it: issue-shaped, with `pull_request` and `draft` for a PR.
    static func searchJSON(number: Int, isPullRequest: Bool) -> String {
        let pull = isPullRequest
            ? #", "draft": true, "pull_request": {"url": "https://api.github.com/repos/octo/hello/pulls/\#(number)"}"#
            : ""
        return """
            {"total_count": 1, "incomplete_results": false, "items": [
             {"id": \(number), "number": \(number), "title": "Item \(number)", "state": "open",
              "html_url": "https://github.com/octo/hello/issues/\(number)", "comments": 0,
              "user": {"id": 1, "login": "octo"}, "labels": [], "updated_at": "2026-11-01T10:00:00Z"\(pull)}]}
            """
    }

    enum SearchList: String, CaseIterable, Sendable {
        case mine, reviewRequested, assigned
    }

    @Test("the My PRs, Review requested and Assigned lists search this repo for @me, with the token to the API host",
          arguments: [
              (SearchList.mine, "repo:octo/hello is:pr is:open author:@me", true),
              (SearchList.reviewRequested, "repo:octo/hello is:pr is:open review-requested:@me", true),
              (SearchList.assigned, "repo:octo/hello is:issue is:open assignee:@me", false),
          ])
    func searchListsQueryTheRepo(list: SearchList, query: String, isPullRequest: Bool) async throws {
        let stub = StubServer { _ in .init(body: Self.searchJSON(number: 7, isPullRequest: isPullRequest)) }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        let items = switch list {
        case .mine: try await client.myOpenPullRequests(in: repo)
        case .reviewRequested: try await client.reviewRequestedPullRequests(in: repo)
        case .assigned: try await client.assignedOpenIssues(in: repo)
        }

        #expect(items.map(\.number) == [7])
        #expect(items.first?.isPullRequest == isPullRequest)
        #expect(items.first?.draft == (isPullRequest ? true : nil))
        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.url?.host() == "api.github.com")
        #expect(request.url?.path() == "/search/issues")
        let queryItems = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(queryItems.first { $0.name == "q" }?.value == query)
        #expect(queryItems.first { $0.name == "per_page" }?.value == "100")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(request.url?.absoluteString.contains(Self.token) == false)
    }

    @Test("a search refuses a repository name that would add its own qualifiers, or a repo on another host")
    func searchRefusesUnsafeRepository() async throws {
        let stub = StubServer { _ in .init(body: Self.searchJSON(number: 1, isPullRequest: true)) }
        let client = try GitHubClient(token: Self.token, session: stub.session)

        let injected = HostedRepository(host: "github.com", owner: "octo", name: "hello is:closed repo:evil/x")
        await #expect(throws: GitHubError.self) { try await client.myOpenPullRequests(in: injected) }
        let otherHost = HostedRepository(host: "ghe.example.com", owner: "octo", name: "hello")
        await #expect(throws: GitHubError.wrongHost("ghe.example.com")) {
            try await client.assignedOpenIssues(in: otherHost)
        }
        #expect(stub.requests.isEmpty)
    }

    // MARK: - Merge

    @Test("a merge pins the reviewed head: the body carries the method and the head sha")
    func mergeSendsHeadSHA() async throws {
        let stub = StubServer { _ in .init(body: #"{"sha": "cafe", "merged": true, "message": "Merged"}"#) }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        try await client.merge(7, in: repo, method: .squash, sha: "abc123")

        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/repos/octo/hello/pulls/7/merge")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["merge_method"] as? String == "squash")
        #expect(body["sha"] as? String == "abc123")
    }

    @Test("a merge GitHub refuses with 409 (the head moved) throws headChanged; another endpoint's 409 stays http")
    func mergeConflictIsHeadChanged() async throws {
        let stub = StubServer { _ in
            .init(status: 409, body: #"{"message": "Head branch was modified. Review and try the merge again."}"#)
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        await #expect(throws: GitHubError.headChanged) {
            try await client.merge(7, in: repo, method: .merge, sha: "abc123")
        }
        #expect(GitHubError.headChanged.description == "The pull request's head changed: reload and review it again.")
        await #expect(throws: GitHubError.http(
            status: 409, message: "Head branch was modified. Review and try the merge again.")) {
            try await client.setOpen(false, number: 7, in: repo)
        }
    }

    // MARK: - Pull request commits and files

    @Test("a PR's commits and files come from its endpoints; a file without a patch or a commit without an account decodes, and a patch parses as read-only hunks")
    func pullRequestCommitsAndFiles() async throws {
        let stub = StubServer { request in
            if request.url?.path() == "/repos/octo/hello/pulls/7/commits" {
                return .init(body: """
                    [{"sha": "aaaa", "html_url": "https://github.com/octo/hello/commit/aaaa",
                      "commit": {"message": "First\\n\\nBody", "author": {"name": "Octo", "email": "o@x.invalid",
                                 "date": "2026-11-01T10:00:00Z"}}, "author": null}]
                    """)
            }
            return .init(body: """
                [{"filename": "src/new.swift", "status": "renamed", "previous_filename": "src/old.swift",
                  "additions": 1, "deletions": 1, "changes": 2, "patch": "@@ -1,2 +1,2 @@ func a()\\n keep\\n-old\\n+new"},
                 {"filename": "logo.png", "status": "added", "additions": 0, "deletions": 0, "changes": 0}]
                """)
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        let commits = try await client.pullRequestCommits(7, in: repo)
        let files = try await client.pullRequestFiles(7, in: repo)

        #expect(commits.map(\.sha) == ["aaaa"])
        #expect(commits.first?.author == nil)
        #expect(commits.first?.commit.author?.name == "Octo")
        #expect(files.map(\.filename) == ["src/new.swift", "logo.png"])
        #expect(files.last?.patch == nil)
        #expect(files.last?.diff == nil)
        let diff = try #require(files.first?.diff)
        #expect(diff.change == .renamed)
        #expect(diff.oldPath == "src/old.swift")
        #expect(diff.newPath == "src/new.swift")
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks.first?.section == "func a()")
        #expect(diff.hunks.first?.lines.map(\.kind) == [.context, .removed, .added])
        #expect(diff.hunks.first?.lines.map(\.text) == ["keep", "old", "new"])
        #expect((diff.additions, diff.deletions) == (1, 1))
        #expect(stub.requests.map { $0.url?.path() } == ["/repos/octo/hello/pulls/7/commits", "/repos/octo/hello/pulls/7/files"])
        for request in stub.requests {
            #expect(request.url?.host() == "api.github.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        }
    }

    // MARK: - Creating a pull request

    @Test("a new PR's form reads the default branch, labels, assignable users and collaborators from the repo's endpoints")
    func createFormListsComeFromTheirEndpoints() async throws {
        let stub = StubServer { request in
            switch request.url?.path() {
            case "/repos/octo/hello": .init(body: #"{"full_name": "octo/hello", "default_branch": "trunk"}"#)
            case "/repos/octo/hello/labels": .init(body: #"[{"name": "bug", "color": "d73a4a"}]"#)
            case "/repos/octo/hello/assignees": .init(body: #"[{"id": 1, "login": "octo"}]"#)
            default: .init(status: 403, headers: ["X-RateLimit-Remaining": "4000"],
                           body: #"{"message": "Must have push access to view repository collaborators."}"#)
            }
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        #expect(try await client.repositoryInfo(repo).defaultBranch == "trunk")
        #expect(try await client.labels(in: repo).map(\.name) == ["bug"])
        #expect(try await client.assignableUsers(in: repo).map(\.login) == ["octo"])
        // A token without push access: the form leaves the reviewers out instead of failing.
        await #expect(throws: GitHubError.forbidden(message: "Must have push access to view repository collaborators.")) {
            try await client.collaborators(in: repo)
        }
        #expect(stub.requests.map { $0.url?.path() } == [
            "/repos/octo/hello", "/repos/octo/hello/labels", "/repos/octo/hello/assignees",
            "/repos/octo/hello/collaborators",
        ])
    }

    @Test("after a create, reviewers, labels and assignees are POSTed to their endpoints with GitHub's body keys")
    func createFollowUpsPostTheirBodies() async throws {
        let stub = StubServer { request in
            request.url?.path().hasSuffix("/labels") == true
                ? .init(body: #"[{"name": "bug"}]"#)
                : .init(status: 201, body: Self.pullJSON(7))
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        let created = try await client.createPullRequest(
            NewPullRequest(title: "Add a", head: "feature/a", base: "main", body: "Why", draft: true), in: repo)
        try await client.requestReviewers(["alice", "bob"], on: created.number, in: repo)
        try await client.addLabels(["bug"], to: created.number, in: repo)
        try await client.addAssignees(["octo"], to: created.number, in: repo)

        let requests = stub.requests
        #expect(requests.map { $0.httpMethod } == ["POST", "POST", "POST", "POST"])
        #expect(requests.map { $0.url?.path() } == [
            "/repos/octo/hello/pulls", "/repos/octo/hello/pulls/7/requested_reviewers",
            "/repos/octo/hello/issues/7/labels", "/repos/octo/hello/issues/7/assignees",
        ])
        let bodies = try requests.map { request in
            try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        }
        #expect(bodies[0]["head"] as? String == "feature/a")
        #expect(bodies[0]["base"] as? String == "main")
        #expect(bodies[0]["draft"] as? Bool == true)
        #expect(bodies[1]["reviewers"] as? [String] == ["alice", "bob"])
        #expect(bodies[2]["labels"] as? [String] == ["bug"])
        #expect(bodies[3]["assignees"] as? [String] == ["octo"])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }
    }

    // MARK: - Remote URLs

    @Test("remote URLs resolve to host/owner/repo, Enterprise scp-style ones included", arguments: [
        ("git@ghe.example.com:Team/app.git", "ghe.example.com", "Team", "app"),
        ("org-1@GHE.Example.com:/team/my.repo", "ghe.example.com", "team", "my.repo"),
        ("https://github.com/octo/hello.git", "github.com", "octo", "hello"),
        ("https://user@ghe.example.com:8443/team/app/", "ghe.example.com:8443", "team", "app"),
        ("ssh://git@ghe.example.com:2222/team/app.git", "ghe.example.com", "team", "app"),
    ])
    func remoteURLResolves(url: String, host: String, owner: String, name: String) throws {
        #expect(GitHubClient.repository(fromRemoteURL: url) == HostedRepository(host: host, owner: owner, name: name))
        let client = try GitHubClient(host: host, token: nil)
        let expectedBase = host == "github.com" ? "https://api.github.com" : "https://\(host)/api/v3"
        #expect(client.apiBase.absoluteString == expectedBase)
    }

    @Test("URLs that are not host/owner/repo, or whose host could widen a config key, resolve to nothing",
          arguments: ["https://github.com/octo", "https://gitlab.com/group/sub/repo.git", "/srv/repo:x", "../repo",
                      "git@host:owner/repo/extra", "https://*.example.com/o/r", "file:///tmp/o/r", "git@ho st:o/r",
                      "http://github.com/o/r", "git@-oops:o/r"])
    func otherURLsDoNotResolve(url: String) {
        #expect(GitHubClient.repository(fromRemoteURL: url) == nil)
    }

    // MARK: - Device flow

    @Test("the device flow waits the interval, polls through authorization_pending and adds 5 s on slow_down")
    func deviceFlowHonoursSlowDown() async throws {
        let polls = Mutex(0)
        let stub = StubServer { request in
            if request.url?.path() == "/login/device/code" {
                return .init(body: """
                    {"device_code": "dev123", "user_code": "ABCD-1234", "verification_uri": "https://github.com/login/device",
                     "expires_in": 900, "interval": 5}
                    """)
            }
            let poll = polls.withLock { count in count += 1; return count }
            switch poll {
            case 1: return .init(body: #"{"error": "authorization_pending"}"#)
            case 2: return .init(body: #"{"error": "slow_down", "error_description": "Too many requests"}"#)
            default: return .init(body: #"{"access_token": "\#(Self.token)", "token_type": "bearer", "scope": "repo"}"#)
            }
        }
        let sleeps = Mutex<[Duration]>([])
        let flow = try GitHubDeviceFlow(
            clientID: "Iv1.test", session: stub.session, sleep: { duration in sleeps.withLock { $0.append(duration) } })

        let code = try await flow.start()
        #expect(code.userCode == "ABCD-1234")
        let token = try await flow.waitForToken(code)

        #expect(token == Self.token)
        #expect(sleeps.withLock { $0 } == [.seconds(5), .seconds(5), .seconds(10)])
        let requests = stub.requests
        #expect(requests.allSatisfy { $0.url?.host() == "github.com" }, "the web host, not the API host")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        let pollBody = String(decoding: requests.last?.httpBody ?? Data(), as: UTF8.self)
        #expect(pollBody.contains("device_code=dev123"))
        #expect(pollBody.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
    }

    @Test("the device flow stops on expired_token, access_denied, and once expires_in has passed", arguments: [
        ("expired_token", 900, GitHubDeviceFlow.DeviceFlowError.expired),
        ("access_denied", 900, .accessDenied),
        ("authorization_pending", 12, .expired),
    ])
    func deviceFlowStops(answer: String, expiresIn: Int, expected: GitHubDeviceFlow.DeviceFlowError) async throws {
        let stub = StubServer { _ in .init(body: #"{"error": "\#(answer)"}"#) }
        let flow = try GitHubDeviceFlow(clientID: "Iv1.test", session: stub.session, sleep: { _ in })
        let code = GitHubDeviceFlow.DeviceCode(
            deviceCode: "dev", userCode: "U", verificationURI: "https://github.com/login/device",
            expiresIn: expiresIn, interval: 5)

        await #expect(throws: expected) { try await flow.waitForToken(code) }
    }
}

/// Serves every request of its own `URLSession` through `StubURLProtocol` and records them (body included).
final class StubServer: Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body: String
        /// Answer with a redirect to this URL instead.
        var redirect: URL?
    }

    let id = UUID().uuidString
    let session: URLSession
    private let state: Mutex<[URLRequest]> = Mutex([])
    let handler: @Sendable (URLRequest) -> Reply

    init(handler: @escaping @Sendable (URLRequest) -> Reply) {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [StubURLProtocol.serverHeader: id]
        session = URLSession(configuration: configuration)
        // Kept for the whole test run: a test's server is tiny, and removing it would race late callbacks.
        StubURLProtocol.servers.withLock { $0[id] = self }
    }

    var requests: [URLRequest] { state.withLock { $0 } }

    fileprivate func record(_ request: URLRequest) { state.withLock { $0.append(request) } }
}

/// Finds the request's `StubServer` by a header the session adds, so concurrent tests never share a handler.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let serverHeader = "X-Histq-Stub"
    static let servers = Mutex<[String: StubServer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            request.httpBody = Self.read(stream)
        }
        let id = request.value(forHTTPHeaderField: Self.serverHeader) ?? ""
        guard let server = Self.servers.withLock({ $0[id] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        server.record(request)
        let reply = server.handler(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if let redirect = reply.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
