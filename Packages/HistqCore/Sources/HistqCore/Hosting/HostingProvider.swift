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
    /// The open pull requests the token's user opened, as issue-shaped search results (no `head`/`base`;
    /// `draft` is set).
    func myOpenPullRequests(in repo: HostedRepository) async throws -> [GitHubIssue]
    /// The open pull requests that ask the token's user (or one of their teams) for a review, as search results.
    func reviewRequestedPullRequests(in repo: HostedRepository) async throws -> [GitHubIssue]
    /// The open issues (no pull requests) assigned to the token's user, as search results.
    func assignedOpenIssues(in repo: HostedRepository) async throws -> [GitHubIssue]
    /// The conversation comments of an issue or a pull request.
    func comments(on number: Int, in repo: HostedRepository) async throws -> [GitHubComment]
    func reviews(of number: Int, in repo: HostedRepository) async throws -> [GitHubReview]
    /// A pull request's commits, oldest first (GitHub lists at most 250).
    func pullRequestCommits(_ number: Int, in repo: HostedRepository) async throws -> [GitHubCommit]
    /// The files a pull request changes, with their patches (GitHub lists at most 3000).
    func pullRequestFiles(_ number: Int, in repo: HostedRepository) async throws -> [GitHubPullRequestFile]
    /// The check runs of a commit (`ref` is a commit id or a branch name).
    func checkRuns(for ref: String, in repo: HostedRepository) async throws -> [GitHubCheckRun]

    /// The repository's own data (its default branch).
    func repositoryInfo(_ repo: HostedRepository) async throws -> GitHubRepositoryInfo
    /// The repository's labels, for a new pull request.
    func labels(in repo: HostedRepository) async throws -> [GitHubLabel]
    /// The users an issue or a pull request can be assigned to.
    func assignableUsers(in repo: HostedRepository) async throws -> [GitHubUser]
    /// The repository's collaborators, the users a review can be requested from (403 without push access).
    func collaborators(in repo: HostedRepository) async throws -> [GitHubUser]

    func createPullRequest(_ pullRequest: NewPullRequest, in repo: HostedRepository) async throws
        -> GitHubPullRequest
    /// Asks `logins` to review pull request `number`.
    func requestReviewers(_ logins: [String], on number: Int, in repo: HostedRepository) async throws
    /// Adds labels (by name) to an issue or a pull request.
    func addLabels(_ names: [String], to number: Int, in repo: HostedRepository) async throws
    /// Assigns `logins` to an issue or a pull request.
    func addAssignees(_ logins: [String], to number: Int, in repo: HostedRepository) async throws
    func comment(on number: Int, in repo: HostedRepository, body: String) async throws -> GitHubComment
    func review(_ number: Int, in repo: HostedRepository, event: HostedReviewEvent, body: String?)
        async throws -> GitHubReview
    /// Merges only while the head is still `sha` (409 otherwise, `GitHubError.headChanged` for GitHub).
    func merge(_ number: Int, in repo: HostedRepository, method: HostedMergeMethod, sha: String) async throws
    /// Closes (`open` false) or reopens an issue or a pull request.
    func setOpen(_ open: Bool, number: Int, in repo: HostedRepository) async throws
}
