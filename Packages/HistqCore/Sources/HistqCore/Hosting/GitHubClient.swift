// GitHub's REST v3 API for github.com (`https://api.github.com`) and GitHub Enterprise Server
// (`https://<host>/api/v3`). The `URLSession` is injected, so tests serve inline JSON through a stub `URLProtocol`
// and never reach the network.
//
// The token is a secret: it only ever goes in the `Authorization` header of a request to the client's own API
// host. A `Link: rel="next"` URL on another origin is refused and a redirect to another origin is not followed (a
// redirected request would carry the header along), no error or description holds it, and `print`, `dump` and
// `String(reflecting:)` of a client show only its host.
import Foundation

public enum GitHubError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A host name that is not a plain DNS name with an optional port.
    case invalidHost(String)
    /// A token with whitespace, control or non-ASCII characters (it would break the header).
    case invalidToken
    /// The repository is on another host than the client's.
    case wrongHost(String)
    /// 401: the token is missing, revoked or expired.
    case unauthorized
    /// 403 that is not a rate limit (missing scope, SSO not authorized, blocked).
    case forbidden(message: String)
    /// 404, which GitHub also answers for a private repository the token cannot see.
    case notFound
    /// The hourly quota is used up (`X-RateLimit-Remaining: 0`); `resetsAt` from `X-RateLimit-Reset`.
    case rateLimited(resetsAt: Date?)
    /// A secondary (abuse) limit: 429, `Retry-After`, or a 403 that says so.
    case secondaryRateLimited(retryAfterSeconds: Int?)
    /// 422: GitHub refused the request's fields (a pull request that already exists, an unknown branch).
    case validationFailed(message: String)
    case http(status: Int, message: String)
    /// A body that is not the expected JSON, or a `Link` to another origin.
    case invalidResponse(String)
    /// The request did not complete (offline, timeout, TLS).
    case transport(String)

    public var description: String {
        switch self {
        case .invalidHost(let host): "Not a valid GitHub host: \(host)"
        case .invalidToken: "The GitHub token has characters a token cannot have."
        case .wrongHost(let host): "The repository is on \(host), not on this account's host."
        case .unauthorized: "GitHub refused the token (revoked or expired). Connect the account again."
        case .forbidden(let message): "GitHub refused the request: \(message)"
        case .notFound: "Not found on GitHub (or the account cannot see it)."
        case .rateLimited(let resetsAt):
            if let resetsAt { "GitHub's rate limit is used up until \(resetsAt.formatted(date: .omitted, time: .shortened))." }
            else { "GitHub's rate limit is used up." }
        case .secondaryRateLimited(let seconds):
            if let seconds { "GitHub asks to slow down; retry in \(seconds) s." } else { "GitHub asks to slow down." }
        case .validationFailed(let message): "GitHub refused the request: \(message)"
        case .http(let status, let message): "GitHub answered \(status): \(message)"
        case .invalidResponse(let detail): "Unexpected answer from GitHub: \(detail)"
        case .transport(let detail): "Could not reach GitHub: \(detail)"
        }
    }
}

public struct GitHubClient: HostingProvider, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// The lowercase host the client talks to (`github.com` or an Enterprise host, with an optional port).
    public let host: String
    /// `https://api.github.com` or `https://<host>/api/v3`.
    public let apiBase: URL
    /// The most pages one list follows (100 items each), so a huge repository cannot keep a list loading.
    public var maxPages = 10
    private let token: String?
    private let session: URLSession

    /// `token` nil reads public data only. Throws `GitHubError.invalidHost` or `.invalidToken`.
    public init(host: String = "github.com", token: String?, session: URLSession = .shared) throws {
        guard let host = Self.validatedHost(host), let apiBase = Self.apiBase(forHost: host) else {
            throw GitHubError.invalidHost(host)
        }
        if let token { guard Self.isUsableToken(token) else { throw GitHubError.invalidToken } }
        self.host = host
        self.apiBase = apiBase
        self.token = token
        self.session = session
    }

    public var description: String { "GitHubClient(\(host), token: \(token == nil ? "none" : "set"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["host": host, "apiBase": apiBase]) }

    // MARK: - Hosts and remote URLs

    /// `host` lowercased when it is a DNS name (letters, digits, `.`, `-`, `_`, not starting with `.` or `-`)
    /// with an optional `:port`; nil otherwise. The strict set keeps it safe in a URL and in a git config key
    /// (`credential.https://<host>.helper`), where `*` would be a wildcard and `/` or `@` would change the URL.
    public static func validatedHost(_ host: String) -> String? {
        let parts = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0]
        let nameOK = !name.isEmpty && name.utf8.count <= 253 && !name.hasPrefix(".") && !name.hasPrefix("-")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
        guard nameOK else { return nil }
        if parts.count == 2 {
            guard parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let port = Int(parts[1]), (1...65535).contains(port) else {
                return nil
            }
        }
        return host.lowercased()
    }

    /// The REST base of `host` (already validated).
    static func apiBase(forHost host: String) -> URL? {
        host == "github.com" ? URL(string: "https://api.github.com") : URL(string: "https://\(host)/api/v3")
    }

    /// The repository of a GitHub remote URL on any host: `https://[user@]host[:port]/owner/repo[.git][/]`,
    /// `ssh://[user@]host[:port]/owner/repo[.git]` (also `git+ssh://`, `ssh+git://`) and the scp-like
    /// `[user@]host:owner/repo[.git]` (a colon before any slash, as in `HostKeyTrust.host(fromRemoteURL:)`). An
    /// https URL keeps its port (it is the API's port too); an ssh port is dropped. Anything else is nil: other
    /// schemes, local paths, and paths that are not exactly `owner/repo`.
    public static func repository(fromRemoteURL url: String) -> HostedRepository? {
        let lower = url.lowercased()
        var authority: Substring
        var path: Substring
        var keepsPort = false
        if let scheme = ["https://", "ssh://", "git+ssh://", "ssh+git://"].first(where: { lower.hasPrefix($0) }) {
            let rest = url.dropFirst(scheme.count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            authority = rest[..<slash]
            path = rest[rest.index(after: slash)...]
            keepsPort = scheme == "https://"
        } else {
            guard !url.contains("://"), let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else {
                return nil
            }
            authority = url[..<colon]
            path = url[url.index(after: colon)...]
            if path.hasPrefix("/") { path = path.dropFirst() }
        }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if !keepsPort, let colon = authority.firstIndex(of: ":") { authority = authority[..<colon] }
        guard let host = validatedHost(String(authority)) else { return nil }

        while path.hasSuffix("/") { path = path.dropLast() }
        if path.lowercased().hasSuffix(".git") { path = path.dropLast(4) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let owner = String(components[0])
        let name = String(components[1])
        guard isSafeSegment(owner, extra: "-_"), isSafeSegment(name, extra: "-_."), name != ".", name != ".." else {
            return nil
        }
        return HostedRepository(host: host, owner: owner, name: name)
    }

    /// Printable ASCII without spaces or backslashes: a newline would end the HTTP header (or a credential helper's
    /// line), and an `echo` that expands backslashes could print `\n` as one. GitHub tokens have neither.
    public static func isUsableToken(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) && $0 != "\\" }
    }

    private static func isSafeSegment(_ text: String, extra: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || extra.unicodeScalars.contains($0))
        }
    }

    // MARK: - HostingProvider

    public func currentUser() async throws -> GitHubUser {
        try await get(url(["user"]))
    }

    public func pullRequests(in repo: HostedRepository, state: HostedListState) async throws -> [GitHubPullRequest] {
        try await list(url(try repoPath(repo) + ["pulls"], query: ["state": state.rawValue]))
    }

    public func pullRequest(_ number: Int, in repo: HostedRepository) async throws -> GitHubPullRequest {
        try await get(url(try repoPath(repo) + ["pulls", String(number)]))
    }

    public func issues(in repo: HostedRepository, state: HostedListState) async throws -> [GitHubIssue] {
        let all: [GitHubIssue] = try await list(url(try repoPath(repo) + ["issues"], query: ["state": state.rawValue]))
        return all.filter { !$0.isPullRequest }
    }

    public func issue(_ number: Int, in repo: HostedRepository) async throws -> GitHubIssue {
        try await get(url(try repoPath(repo) + ["issues", String(number)]))
    }

    public func comments(on number: Int, in repo: HostedRepository) async throws -> [GitHubComment] {
        try await list(url(try repoPath(repo) + ["issues", String(number), "comments"]))
    }

    public func reviews(of number: Int, in repo: HostedRepository) async throws -> [GitHubReview] {
        try await list(url(try repoPath(repo) + ["pulls", String(number), "reviews"]))
    }

    public func checkRuns(for ref: String, in repo: HostedRepository) async throws -> [GitHubCheckRun] {
        struct Page: Decodable {
            var checkRuns: [GitHubCheckRun]
            enum CodingKeys: String, CodingKey { case checkRuns = "check_runs" }
        }
        let first = url(try repoPath(repo) + ["commits", ref, "check-runs"])
        return try await paginated(first) { (page: Page) in page.checkRuns }
    }

    public func createPullRequest(_ pullRequest: NewPullRequest, in repo: HostedRepository) async throws
        -> GitHubPullRequest
    {
        struct Body: Encodable { var title, head, base: String; var body: String?; var draft: Bool }
        let body = Body(
            title: pullRequest.title, head: pullRequest.head, base: pullRequest.base, body: pullRequest.body,
            draft: pullRequest.draft)
        return try await send("POST", url(try repoPath(repo) + ["pulls"]), body: body)
    }

    public func comment(on number: Int, in repo: HostedRepository, body: String) async throws -> GitHubComment {
        try await send("POST", url(try repoPath(repo) + ["issues", String(number), "comments"]), body: ["body": body])
    }

    public func review(_ number: Int, in repo: HostedRepository, event: HostedReviewEvent, body: String?)
        async throws -> GitHubReview
    {
        struct Body: Encodable { var event: String; var body: String? }
        return try await send(
            "POST", url(try repoPath(repo) + ["pulls", String(number), "reviews"]),
            body: Body(event: event.rawValue, body: body))
    }

    public func merge(_ number: Int, in repo: HostedRepository, method: HostedMergeMethod) async throws {
        struct Result: Decodable { var merged: Bool? }
        let _: Result = try await send(
            "PUT", url(try repoPath(repo) + ["pulls", String(number), "merge"]),
            body: ["merge_method": method.rawValue])
    }

    public func setOpen(_ open: Bool, number: Int, in repo: HostedRepository) async throws {
        struct Result: Decodable { var number: Int }
        let _: Result = try await send(
            "PATCH", url(try repoPath(repo) + ["issues", String(number)]),
            body: ["state": open ? "open" : "closed"])
    }

    // MARK: - Requests

    private func repoPath(_ repo: HostedRepository) throws -> [String] {
        guard repo.host.lowercased() == host else { throw GitHubError.wrongHost(repo.host) }
        return ["repos", repo.owner, repo.name]
    }

    /// `apiBase` plus `segments`, each percent-encoded as one path segment (a `/` in a branch name stays inside
    /// its segment), and `query`.
    private func url(_ segments: [String], query: [String: String] = [:]) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath += segments
            .map { "/" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined()
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, _) = try await perform(request("GET", url))
        return try GitHubHTTP.decode(data)
    }

    private func send<T: Decodable, Body: Encodable>(_ method: String, _ url: URL, body: Body) async throws -> T {
        var request = request(method, url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await perform(request)
        return try GitHubHTTP.decode(data)
    }

    /// Every page of a list endpoint that answers a JSON array.
    private func list<T: Decodable>(_ first: URL) async throws -> [T] {
        try await paginated(first) { (page: [T]) in page }
    }

    /// Follows `Link: rel="next"` from `first` (with `per_page=100`), up to `maxPages` pages. A next URL on
    /// another origin than `apiBase` throws: following it would send the token there.
    private func paginated<Page: Decodable, Item>(_ first: URL, items: (Page) -> [Item]) async throws -> [Item] {
        var components = URLComponents(url: first, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "per_page", value: "100")]
        var next: URL? = components.url!
        var result: [Item] = []
        var pages = 0
        while let url = next, pages < maxPages {
            let (data, response) = try await perform(request("GET", url))
            let page: Page = try GitHubHTTP.decode(data)
            result += items(page)
            pages += 1
            next = GitHubHTTP.nextLink(response.value(forHTTPHeaderField: "Link"))
            if let next, !GitHubHTTP.isSameOrigin(next, apiBase) {
                throw GitHubError.invalidResponse("a next-page link to another host")
            }
        }
        return result
    }

    private func request(_ method: String, _ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // `full+json` adds `body_html` (GitHub's sanitized HTML) next to the markdown `body`.
        request.setValue("application/vnd.github.full+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Histq", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await GitHubHTTP.load(request, session: session)
        guard (200..<300).contains(response.statusCode) else { throw GitHubHTTP.error(for: response, data: data) }
        return (data, response)
    }
}

/// What the client and the device flow share: loading with the redirect guard, status mapping, JSON, `Link`.
enum GitHubHTTP {
    static func load(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: SameOriginRedirects())
        } catch let error as URLError {
            // The code only: `localizedDescription` can carry the failing URL, which is never a secret here, but
            // a short code is all the UI needs.
            throw GitHubError.transport("URL error \(error.code.rawValue)")
        }
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse("not HTTP") }
        return (data, http)
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GitHubError.invalidResponse("unexpected JSON for \(T.self)")
        }
    }

    /// 401 is auth; a 403 or 429 is the primary rate limit with `X-RateLimit-Remaining: 0`, a secondary one with
    /// `Retry-After`, a 429 or GitHub's "secondary rate limit" message, and otherwise a plain refusal.
    static func error(for response: HTTPURLResponse, data: Data) -> GitHubError {
        struct Body: Decodable { var message: String? }
        let message = String(((try? JSONDecoder().decode(Body.self, from: data))?.message ?? "").prefix(500))
        let status = response.statusCode
        switch status {
        case 401:
            return .unauthorized
        case 403, 429:
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
                return .rateLimited(resetsAt: reset.map { Date(timeIntervalSince1970: $0) })
            }
            if let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap({ Int($0) }) {
                return .secondaryRateLimited(retryAfterSeconds: retry)
            }
            if status == 429 || message.localizedCaseInsensitiveContains("secondary rate limit") {
                return .secondaryRateLimited(retryAfterSeconds: nil)
            }
            return .forbidden(message: message)
        case 404:
            return .notFound
        case 422:
            return .validationFailed(message: message)
        default:
            return .http(status: status, message: message)
        }
    }

    /// The `rel="next"` URL of a `Link` header (`<url>; rel="next", <url>; rel="last"`).
    static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let fields = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = fields.first, target.hasPrefix("<"), target.hasSuffix(">") else { continue }
            let isNext = fields.dropFirst().contains { field in
                let pair = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, pair[0].lowercased() == "rel" else { return false }
                return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    .split(separator: " ").contains("next")
            }
            if isNext { return URL(string: String(target.dropFirst().dropLast())) }
        }
        return nil
    }

    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased()
            && a.port == b.port
    }
}

/// Refuses a redirect to another origin: URLSession would copy the `Authorization` header to the new request.
/// The 3xx answer then fails as an HTTP error.
private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let from = task.originalRequest?.url, let to = request.url, GitHubHTTP.isSameOrigin(from, to) else {
            return nil
        }
        return request
    }
}
