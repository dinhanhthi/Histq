#if DEBUG
// DEBUG `-HistqGitHubStub YES`: the PRs tab, the PR and issue details and the create form without GitHub. `GitHubStore`
// then uses the repository `stub/stub` on github.com (the fixtures' origin is a local bare repo, which names no GitHub
// repo), a fake token, and a `URLSession` whose only protocol is `GitHubStubProtocol`: it answers every request from
// the JSON below (PR #1's merge, a 409 when it is not pinned to its head, review, comment and close/reopen, issue #2's
// comment and close/reopen, and a create that always makes PR #3 with its reviewers, labels and assignees succeed) and
// 404 for anything else, so a stub run never reaches the network. The data: user `stub`, open pull request #1 "Add
// feature" (`feature` into `main`, 2 commits, 1 changed file, 1 review, 1 comment, 1 check run) by `stub`, open issue
// #2 assigned to `stub` with 1 comment, the repository's labels, assignable users and collaborators (`stub`,
// `reviewer`), and default branch `main`. The JSON has GitHub's shapes (search results are issue-shaped), so the stub
// exercises the same decoding as the real API.
import Foundation
import HistqCore

enum GitHubStub {
    static let isEnabled = AppState.launchFlag("-HistqGitHubStub") == "YES"
    static let repository = HostedRepository(host: "github.com", owner: "stub", name: "stub")
    /// Never a real token: nothing leaves the stub session.
    static let token = "histq_stub_fake_token"
    /// PR #1's head commit (the stub's check runs belong to it).
    static let headSHA = "1111111111111111111111111111111111111111"
    static let baseSHA = "2222222222222222222222222222222222222222"
    /// A head PR #1 had before a push: a merge pinned to it gets GitHub's 409 (`-HistqPRAction merge-stale`).
    static let staleSHA = "6666666666666666666666666666666666666666"

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubStubProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func client() -> GitHubClient? {
        try? GitHubClient(host: repository.host, token: token, session: session)
    }

    /// The status and JSON body for a request of the stub session (`body`: the request's).
    static func reply(method: String, url: URL, body: Data?) -> (status: Int, body: String) {
        let repo = "/repos/\(repository.owner)/\(repository.name)"
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard url.host() == "api.github.com" else { return notFound }
        // The PR detail's actions answer as GitHub does, so their flows run in a stub launch; nothing changes (a
        // merged or closed #1 still reads as open on the reload).
        switch (method, url.path()) {
        case ("PUT", "\(repo)/pulls/1/merge"):
            // GitHub refuses a merge pinned to another head than the current one.
            let sha = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["sha"] as? String
            guard sha == headSHA else {
                return (409, #"{"message": "Head branch was modified. Review and try the merge again."}"#)
            }
            return (200, #"{"sha": "\#(headSHA)", "merged": true, "message": "Merged"}"#)
        case ("POST", "\(repo)/pulls/1/reviews"): return (200, review)
        case ("POST", "\(repo)/issues/1/comments"): return (201, comment)
        case ("PATCH", "\(repo)/issues/1"): return (200, pullAsIssue)
        case ("POST", "\(repo)/issues/2/comments"): return (201, issueComment)
        case ("PATCH", "\(repo)/issues/2"): return (200, issue)
        // A create always makes #3, whatever the form sent (the stub keeps no state); its follow-ups succeed.
        case ("POST", "\(repo)/pulls"): return (201, pull(3, full: true))
        case ("POST", "\(repo)/pulls/3/requested_reviewers"): return (201, pull(3, full: true))
        case ("POST", "\(repo)/issues/3/labels"): return (200, "[\(labels)]")
        case ("POST", "\(repo)/issues/3/assignees"): return (201, pull(3, full: true))
        case ("GET", _): break
        default: return notFound
        }
        switch url.path() {
        case "/user": return (200, user)
        case repo: return (200, #"{"full_name": "stub/stub", "default_branch": "main"}"#)
        case "\(repo)/labels": return (200, "[\(labels)]")
        case "\(repo)/assignees", "\(repo)/collaborators": return (200, "[\(user), \(reviewer)]")
        case "\(repo)/pulls": return (200, "[\(pull(1, full: false))]")
        case "\(repo)/pulls/1": return (200, pull(1, full: true))
        case "\(repo)/pulls/1/reviews": return (200, "[\(review)]")
        case "\(repo)/pulls/1/commits": return (200, commits)
        case "\(repo)/pulls/1/files": return (200, files)
        case "\(repo)/pulls/3": return (200, pull(3, full: true))
        case "\(repo)/pulls/3/reviews", "\(repo)/pulls/3/files", "\(repo)/issues/3/comments": return (200, "[]")
        case "\(repo)/pulls/3/commits": return (200, "[\(createdCommit)]")
        case "\(repo)/issues": return (200, "[\(issue), \(pullAsIssue)]")
        case "\(repo)/issues/1": return (200, pullAsIssue)
        case "\(repo)/issues/2": return (200, issue)
        case "\(repo)/issues/1/comments": return (200, "[\(comment)]")
        case "\(repo)/issues/2/comments": return (200, "[\(issueComment)]")
        case "\(repo)/commits/\(headSHA)/check-runs", "\(repo)/commits/feature/check-runs":
            return (200, #"{"total_count": 1, "check_runs": [\#(checkRun)]}"#)
        case let path where path.hasPrefix("\(repo)/commits/") && path.hasSuffix("/check-runs"):
            return (200, #"{"total_count": 0, "check_runs": []}"#)
        case "/search/issues":
            let q = query.first { $0.name == "q" }?.value ?? ""
            guard q.contains("repo:\(repository.fullName)") else { return (200, search([])) }
            if q.contains("author:@me") { return (200, search([pullAsIssue])) }
            if q.contains("assignee:@me") { return (200, search([issue])) }
            // `stub` opened #1, so no pull request asks them for a review: the card's empty state.
            return (200, search([]))
        default:
            return notFound
        }
    }

    private static let notFound = (404, #"{"message": "Not Found"}"#)

    private static let user = """
        {"id": 1001, "login": "stub", "name": "Stub User", "html_url": "https://github.com/stub",
         "avatar_url": "https://avatars.githubusercontent.com/u/1001"}
        """

    private static let reviewer = """
        {"id": 1002, "login": "reviewer", "html_url": "https://github.com/reviewer",
         "avatar_url": "https://avatars.githubusercontent.com/u/1002"}
        """

    /// PR #1, or #3 as a create makes it (the fixture's one commit on `origin/feature` past `origin/main`).
    private static func pull(_ number: Int, full: Bool) -> String {
        let created = number == 3
        let detail = !full ? ""
            : created ? #", "merged": false, "mergeable": true, "commits": 1, "additions": 1, "deletions": 0, "changed_files": 0"#
            : #", "merged": false, "mergeable": true, "commits": 2, "additions": 12, "deletions": 3, "changed_files": 1"#
        let title = created ? "Polish feature (pushed)" : "Add feature"
        let body = created ? "Polishes the feature." : "Adds the feature branch's work."
        return """
            {"id": \(500 + number), "number": \(number), "title": "\(title)", "state": "open", "draft": false,
             "html_url": "https://github.com/stub/stub/pull/\(number)", "user": \(user),
             "body": "\(body)", "body_html": "<p>\(body)</p>",
             "head": {"label": "stub:feature", "ref": "feature", "sha": "\(created ? createdSHA : headSHA)"},
             "base": {"label": "stub:main", "ref": "main", "sha": "\(baseSHA)"},
             "labels": [\(created ? "" : #"{"name": "enhancement", "color": "a2eeef", "description": "New feature"}"#)],
             "assignees": [\(user)], "requested_reviewers": [\(reviewer)],
             "created_at": "2026-11-10T09:00:00Z", "updated_at": "2026-11-12T16:30:00Z"\(detail)}
            """
    }

    /// PR #3's head commit.
    private static let createdSHA = "5555555555555555555555555555555555555555"

    private static let createdCommit = """
        {"sha": "\(createdSHA)", "html_url": "https://github.com/stub/stub/commit/5555555",
         "commit": {"message": "Polish feature (pushed)", "author": {"name": "Stub User", "email": "stub@histq.invalid",
                    "date": "2026-11-12T17:00:00Z"}}, "author": \(user)}
        """

    private static let labels = """
        {"name": "enhancement", "color": "a2eeef", "description": "New feature"},
        {"name": "bug", "color": "d73a4a", "description": "Something is not working"},
        {"name": "documentation", "color": "0075ca"}
        """

    private static let issueComment = """
        {"id": 802, "user": \(user), "body": "I can reproduce it on 0.1.", "body_html": "<p>I can reproduce it on 0.1.</p>",
         "html_url": "https://github.com/stub/stub/issues/2#issuecomment-802",
         "created_at": "2026-11-12T11:00:00Z", "updated_at": "2026-11-12T11:00:00Z"}
        """

    /// PR #1 as the issues API and search return it: issue-shaped, with `pull_request` and `draft`.
    private static let pullAsIssue = """
        {"id": 501, "number": 1, "title": "Add feature", "state": "open", "draft": false,
         "html_url": "https://github.com/stub/stub/pull/1", "user": \(user), "comments": 1,
         "body": "Adds the feature branch's work.", "labels": [{"name": "enhancement", "color": "a2eeef"}],
         "assignees": [\(user)], "created_at": "2026-11-10T09:00:00Z", "updated_at": "2026-11-12T16:30:00Z",
         "pull_request": {"url": "https://api.github.com/repos/stub/stub/pulls/1"}}
        """

    private static let issue = """
        {"id": 602, "number": 2, "title": "Crash when opening an empty repository", "state": "open",
         "html_url": "https://github.com/stub/stub/issues/2", "user": \(reviewer), "comments": 1,
         "body": "Steps: open an empty folder.", "body_html": "<p>Steps: open an empty folder.</p>",
         "labels": [{"name": "bug", "color": "d73a4a"}], "assignees": [\(user)],
         "created_at": "2026-11-11T08:00:00Z", "updated_at": "2026-11-12T10:00:00Z"}
        """

    private static let review = """
        {"id": 701, "user": \(reviewer), "state": "APPROVED", "body": "Looks good.", "body_html": "<p>Looks good.</p>",
         "html_url": "https://github.com/stub/stub/pull/1#pullrequestreview-701", "submitted_at": "2026-11-12T15:00:00Z"}
        """

    private static let comment = """
        {"id": 801, "user": \(reviewer), "body": "Nice work.", "body_html": "<p>Nice work.</p>",
         "html_url": "https://github.com/stub/stub/pull/1#issuecomment-801",
         "created_at": "2026-11-12T14:00:00Z", "updated_at": "2026-11-12T14:00:00Z"}
        """

    private static let checkRun = """
        {"id": 901, "name": "build", "status": "completed", "conclusion": "success",
         "html_url": "https://github.com/stub/stub/runs/901",
         "started_at": "2026-11-12T16:31:00Z", "completed_at": "2026-11-12T16:35:00Z"}
        """

    private static let commits = """
        [{"sha": "3333333333333333333333333333333333333333", "html_url": "https://github.com/stub/stub/commit/3333333",
          "commit": {"message": "Start the feature", "author": {"name": "Stub User", "email": "stub@histq.invalid",
                     "date": "2026-11-10T08:50:00Z"}}, "author": \(user)},
         {"sha": "\(headSHA)", "html_url": "https://github.com/stub/stub/commit/1111111",
          "commit": {"message": "Finish the feature", "author": {"name": "Stub User", "email": "stub@histq.invalid",
                     "date": "2026-11-12T16:20:00Z"}}, "author": \(user)}]
        """

    private static let files = """
        [{"sha": "4444444444444444444444444444444444444444", "filename": "feature.txt", "status": "modified",
          "additions": 12, "deletions": 3, "changes": 15,
          "patch": "@@ -1,5 +1,14 @@\\n # Feature\\n-TODO: write the feature\\n-old line\\n-another old line\\n+The feature does three things:\\n+\\n+1. reads the input\\n+2. checks it\\n+3. writes the output\\n+\\n+Usage:\\n+\\n+    feature --input file\\n+\\n+See the docs for details.\\n+Done.\\n End."}]
        """

    private static func search(_ items: [String]) -> String {
        #"{"total_count": \#(items.count), "incomplete_results": false, "items": [\#(items.joined(separator: ", "))]}"#
    }
}

/// Answers every request of `GitHubStub.session` itself: never passes one on to the network.
final class GitHubStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let reply = request.url.map {
            GitHubStub.reply(method: request.httpMethod ?? "GET", url: $0,
                             body: request.httpBody ?? request.httpBodyStream.map(Self.read))
        }
        guard let url = request.url, let reply,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// A request's body: URLSession hands it to the protocol as a stream.
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
#endif
