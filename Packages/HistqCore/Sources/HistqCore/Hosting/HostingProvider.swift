// The small surface the app needs from a code host: which repository a remote URL names, its pull requests and
// issues, and the few actions Histq offers on them. GitHub (and GitHub Enterprise) is the only provider, so the
// protocol speaks in GitHub's models (`GitHubModels.swift`); another provider would map its JSON into them.
import Foundation

/// A repository on a code host: `host` is lowercase and keeps an https port (`ghe.example.com:8443`).
public struct HostedRepository: Codable, Sendable, Hashable {
    public var host: String
    public var owner: String
    public var name: String

    public init(host: String, owner: String, name: String) {
        self.host = host
        self.owner = owner
        self.name = name
    }

    /// `owner/name`.
    public var fullName: String { "\(owner)/\(name)" }
}

/// Which pull requests or issues a list returns.
public enum HostedListState: String, Sendable {
    case open, closed, all
}

/// What a review says (`POST .../reviews` `event`).
public enum HostedReviewEvent: String, Sendable {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"
}

/// How a pull request is merged (`PUT .../merge` `merge_method`).
public enum HostedMergeMethod: String, Sendable {
    case merge, squash, rebase
}

/// A pull request to open: `head` is the branch with the changes (`owner:branch` for a fork), `base` the
/// branch it goes into.
public struct NewPullRequest: Sendable, Equatable {
    public var title: String
    public var head: String
    public var base: String
    public var body: String?
    public var draft: Bool

    public init(title: String, head: String, base: String, body: String? = nil, draft: Bool = false) {
        self.title = title
        self.head = head
        self.base = base
        self.body = body
        self.draft = draft
    }
}

public protocol HostingProvider: Sendable {
    /// The repository a remote URL names, or nil when the URL is not a host/owner/repo URL.
    static func repository(fromRemoteURL url: String) -> HostedRepository?

    /// The account the token belongs to.
    func currentUser() async throws -> GitHubUser

    func pullRequests(in repo: HostedRepository, state: HostedListState) async throws -> [GitHubPullRequest]
    func pullRequest(_ number: Int, in repo: HostedRepository) async throws -> GitHubPullRequest
    /// Issues only: the pull requests GitHub also lists as issues are left out.
    func issues(in repo: HostedRepository, state: HostedListState) async throws -> [GitHubIssue]
    func issue(_ number: Int, in repo: HostedRepository) async throws -> GitHubIssue
    /// The conversation comments of an issue or a pull request.
    func comments(on number: Int, in repo: HostedRepository) async throws -> [GitHubComment]
    func reviews(of number: Int, in repo: HostedRepository) async throws -> [GitHubReview]
    /// The check runs of a commit (`ref` is a commit id or a branch name).
    func checkRuns(for ref: String, in repo: HostedRepository) async throws -> [GitHubCheckRun]

    func createPullRequest(_ pullRequest: NewPullRequest, in repo: HostedRepository) async throws
        -> GitHubPullRequest
    func comment(on number: Int, in repo: HostedRepository, body: String) async throws -> GitHubComment
    func review(_ number: Int, in repo: HostedRepository, event: HostedReviewEvent, body: String?)
        async throws -> GitHubReview
    func merge(_ number: Int, in repo: HostedRepository, method: HostedMergeMethod) async throws
    /// Closes (`open` false) or reopens an issue or a pull request.
    func setOpen(_ open: Bool, number: Int, in repo: HostedRepository) async throws
}
