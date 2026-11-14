// One repo tab's GitHub side, behind the sidebar's PRs tab and the graph's PR badges: which GitHub repository the tab's
// remotes name, with the tab profile's account and token, and its four lists (My PRs, Review requested, All open,
// Issues assigned to me), kept between visits of the tab. The repo tab drives it while it shows (`watch`, from
// `GitHubDriver`): a first load for the badges, a load when the window shows again and the last one is older than
// `staleAfter`, and one every `refreshInterval` only while the PRs tab shows; none once the repo tab closes or there is
// no connected account. Every request runs off the main actor; the token is read there too and only lives inside the
// `GitHubClient`, never in observable state.
import Foundation
import HistqCore
import os

/// A row of the PRs tab: a pull request or an issue, as much of it as the row draws.
struct HostedRow: Identifiable, Equatable, Sendable {
    let item: HostedItem
    let title: String
    let authorLogin: String?
    let authorID: Int?
    let isDraft: Bool
    /// A pull request's head commit, whose check runs give the row's checks state; nil for an issue, or a search hit
    /// that is not in the All open list.
    let headSHA: String?

    var id: HostedItem { item }
    var number: Int { item.number }
}

extension HostedRow {
    init(pull: GitHubPullRequest) {
        self.init(item: .pullRequest(pull.number), title: pull.title, authorLogin: pull.user?.login,
                  authorID: pull.user?.id, isDraft: pull.draft ?? false, headSHA: pull.head.sha)
    }

    /// A search hit (issue-shaped): the pull request, when All open has it, gives the head commit.
    init(searchHit hit: GitHubIssue, pull: GitHubPullRequest?) {
        self.init(item: hit.isPullRequest ? .pullRequest(hit.number) : .issue(hit.number), title: hit.title,
                  authorLogin: hit.user?.login, authorID: hit.user?.id,
                  isDraft: hit.draft ?? pull?.draft ?? false, headSHA: pull?.head.sha)
    }
}

/// What panel2 shows instead of the graph after a click in the PRs tab.
enum HostedItem: Hashable, Sendable {
    case pullRequest(Int)
    case issue(Int)

    var number: Int {
        switch self {
        case .pullRequest(let number), .issue(let number): number
        }
    }

    /// The timing log's detail: `pr 1`, `issue 2`.
    var timingDetail: String {
        switch self {
        case .pullRequest(let number): "pr \(number)"
        case .issue(let number): "issue \(number)"
        }
    }
}

/// A pull request's check runs, summed up: any failed run fails, any unfinished one is pending.
enum ChecksState: Equatable, Sendable {
    case success, failure, pending

    /// nil when the commit has no check runs.
    init?(_ runs: [GitHubCheckRun]) {
        guard !runs.isEmpty else { return nil }
        let failed: Set<String> = ["failure", "timed_out", "cancelled", "action_required", "startup_failure"]
        if runs.contains(where: { failed.contains($0.conclusion ?? "") }) {
            self = .failure
        } else if runs.contains(where: { $0.status != "completed" }) {
            self = .pending
        } else {
            self = .success
        }
    }
}

@Observable
@MainActor
final class GitHubStore {
    enum List: String, CaseIterable, Sendable {
        case mine, reviewRequested, allOpen, assigned

        var title: String {
            switch self {
            case .mine: "My PRs"
            case .reviewRequested: "Review requested"
            case .allOpen: "All open"
            case .assigned: "Issues"
            }
        }

        var systemImage: String {
            switch self {
            case .mine: "person"
            case .reviewRequested: "eye"
            case .allOpen: "arrow.triangle.pull"
            case .assigned: "smallcircle.filled.circle"
            }
        }

        var emptyText: String {
            switch self {
            case .mine: "No open pull requests of yours"
            case .reviewRequested: "No review requests"
            case .allOpen: "No open pull requests"
            case .assigned: "No open issues assigned to you"
            }
        }
    }

    enum Connection: Equatable {
        /// The profiles, the remotes or the token are still being read.
        case resolving
        /// No profile, no GitHub account on it, or (`account` set) its token is not in the Keychain: the Connect card.
        case notConnected(account: Profile.GitHubAccount?)
        /// Connected, but no remote of the repo is on the account's host.
        case noRemote(host: String)
        case connected(HostedRepository)
    }

    /// Why a list could not be read; `reconnect` when GitHub refused the token.
    struct ListError: Equatable {
        let message: String
        let reconnect: Bool
    }

    /// A list's rows (nil until the first read) and the last read's error, shown above the rows it kept.
    struct ListState: Equatable {
        var rows: [HostedRow]?
        var error: ListError?
    }

    /// What `watch` resolves from: the PRs tab's `.task(id:)` key, so any change restarts it.
    struct Source: Equatable, Sendable {
        var profilesLoaded: Bool
        var profileID: UUID?
        var account: Profile.GitHubAccount?
        /// The tab's remotes; `remotesKnown` false until the first refs read has listed them.
        var remotes: [RemoteInfo]
        var remotesKnown: Bool
        /// Settings closing resolves again: a reconnect of the same account changes no other value, only the token.
        var settingsOpen: Bool
        /// The window shows on screen (`WindowState`): no refresh while it is hidden, minimized or covered, and
        /// one (when stale) as it shows again.
        var windowVisible: Bool
        /// The sidebar shows the PRs tab: only then do the lists refresh every `refreshInterval`.
        var listsShown: Bool
        var isStub: Bool

        /// The source without what only decides the polling (`windowVisible`, `listsShown`).
        var withoutPolling: Source {
            var source = self
            source.windowVisible = false
            source.listsShown = false
            return source
        }
    }

    /// The lists' refresh while the PRs tab shows.
    static let refreshInterval: Duration = .seconds(120)
    /// A visit of the PRs tab (or the app becoming active) reloads lists older than this.
    static let staleAfter: TimeInterval = 30
    /// The most head commits whose check runs one refresh reads (one request each): My PRs and Review requested
    /// first, then All open from the top.
    static let maxCheckedCommits = 20

    private(set) var connection: Connection = .resolving
    private(set) var lists: [List: ListState] = [:]
    /// The checks state by head commit; absent while unknown or when the commit has no check runs.
    private(set) var checks: [String: ChecksState] = [:]
    /// The cards' collapsed sections, kept between visits.
    var collapsed: Set<List> = []
    /// The open pull requests whose head branch is in the tab's repository, by that branch's remote-tracking name on
    /// the GitHub remote (`origin/feature`): the graph's PR badges. A fork's pull request is left out: its head is in
    /// another repository, so a branch of the same name here is not its head.
    private(set) var branchPullRequests: [String: RefBadge.PullRequest] = [:]
    /// A pull request or issue action that failed after its detail gave way to another one (or closed): above the PRs
    /// tab's lists, naming the number, until dismissed or replaced by the next one.
    var actionNotice: String?

    @ObservationIgnored private var client: GitHubClient?
    /// The source `client`'s token was read for, without the polling flags: the same one again keeps the client, so
    /// the window showing or the PRs tab opening does not read the Keychain.
    @ObservationIgnored private var clientSource: Source?
    /// The profile, account and repository the lists belong to; another one clears them.
    @ObservationIgnored private var identity: Identity?
    /// Bumped by every resolve and refresh: a late answer of an older one is dropped.
    @ObservationIgnored private var resolveGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var lastRefresh: Date?
    /// After a rate limit: no request before this.
    @ObservationIgnored private var pausedUntil: Date?
    /// Head commits whose checks all passed: not read again. A failure is read again, since a re-run on the same head
    /// may pass.
    @ObservationIgnored private var settledChecks: Set<String> = []
    /// A refresh started outside `watch` (the app became active); cancelled by `stop`.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private struct Identity: Equatable {
        let profileID: UUID?
        let account: Profile.GitHubAccount?
        let repository: HostedRepository
        /// The remote whose URL names `repository`: a pull request's Checkout locally fetches from it.
        let remote: String
    }

    private static let logger = Logger(subsystem: "com.math2it.histq", category: "github")

    deinit {
        refreshTask?.cancel()
    }

    /// The tab closed: no refresh runs any more.
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration &+= 1
        resolveGeneration &+= 1
    }

    // MARK: Driving

    /// Runs while the repo tab shows (`GitHubDriver`'s `.task(id: source)`): resolves the connection, loads the lists
    /// when they were never read or are stale, then, while the PRs tab shows, every `refreshInterval` until cancelled.
    /// Returns at once when not connected; returns after the first load while the window is not visible (a background
    /// launch still gets its lists) or the PRs tab is not shown (the badges need one read, not polling).
    func watch(_ source: Source, profile: Profile?) async {
        await resolve(source, profile: profile)
        guard case .connected = connection, !Task.isCancelled else { return }
        // A list GitHub refused the token for loads again at once: the account may just have been reconnected.
        let refused = lists.values.contains { $0.error?.reconnect == true }
        if lastRefresh == nil || (source.windowVisible && (isStale || refused)) { await refresh() }
        guard source.windowVisible, source.listsShown else { return }
        while (try? await Task.sleep(for: Self.refreshInterval)) != nil {
            await refresh()
        }
    }

    /// The app became active while the PRs tab shows: reloads stale lists.
    func refreshIfStale() {
        guard case .connected = connection, isStale else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    private var isStale: Bool {
        lastRefresh.map { Date.now.timeIntervalSince($0) > Self.staleAfter } ?? true
    }

    /// Whether a list has been read (rows or an error): DEBUG `-HistqSelect pr:<n>` waits for All open.
    func isRead(_ list: List) -> Bool {
        lists[list].map { $0.rows != nil || $0.error != nil } ?? false
    }

    /// The row of `item` in any list.
    func row(for item: HostedItem) -> HostedRow? {
        for list in List.allCases {
            if let row = lists[list]?.rows?.first(where: { $0.item == item }) { return row }
        }
        return nil
    }

    /// The item numbered `number`: a pull request unless only the Issues list has it.
    func item(numbered number: Int) -> HostedItem {
        row(for: .pullRequest(number))?.item ?? row(for: .issue(number))?.item ?? .pullRequest(number)
    }

    // MARK: Resolving

    private func resolve(_ source: Source, profile: Profile?) async {
        resolveGeneration &+= 1
        let generation = resolveGeneration
        #if DEBUG
        if source.isStub {
            client = GitHubStub.client()
            // The fixtures' origin names no GitHub repository; a stub checkout fetches from it (and fails there).
            return connect(Identity(profileID: nil, account: nil, repository: GitHubStub.repository, remote: "origin"))
        }
        #endif
        guard source.profilesLoaded else { return setConnection(.resolving) }
        guard let profile, let account = profile.github else { return disconnect(.notConnected(account: nil)) }
        guard source.remotesKnown else { return setConnection(.resolving) }
        guard let (remote, repository) = Self.remote(in: source.remotes, host: account.host) else {
            return disconnect(.noRemote(host: account.host))
        }
        let identity = Identity(profileID: profile.id, account: account, repository: repository, remote: remote)
        // Settings closing (`settingsOpen`) still reads the token again: a reconnect changes nothing else. So does a
        // list GitHub refused the token for.
        let key = source.withoutPolling
        if client != nil, identity == self.identity, key == clientSource,
           !lists.values.contains(where: { $0.error?.reconnect == true })
        {
            return connect(identity)
        }
        if identity != self.identity {
            // The cards show skeletons, never the last account's or repository's rows, while the token is read.
            self.identity = nil
            forgetLists()
            setConnection(.resolving)
        }
        let client = await Self.makeClient(profile: profile, host: account.host)
        guard generation == resolveGeneration, !Task.isCancelled else { return }
        guard let client else { return disconnect(.notConnected(account: account)) }
        self.client = client
        clientSource = key
        connect(identity)
    }

    private func connect(_ identity: Identity) {
        if identity != self.identity { forgetLists() }
        self.identity = identity
        setConnection(.connected(identity.repository))
    }

    private func disconnect(_ connection: Connection) {
        client = nil
        clientSource = nil
        identity = nil
        forgetLists()
        setConnection(connection)
    }

    private func setConnection(_ connection: Connection) {
        guard self.connection != connection else { return }
        self.connection = connection
        switch connection {
        case .notConnected(let account): UITiming.content(account == nil ? "prs not-connected" : "prs token-missing")
        case .noRemote(let host): UITiming.content("prs no-remote \(host)")
        case .resolving, .connected: break
        }
    }

    /// Another account or repository: nothing of the old one may show, and its answers still in flight are dropped.
    private func forgetLists() {
        refreshGeneration &+= 1
        if !lists.isEmpty { lists = [:] }
        if !checks.isEmpty { checks = [:] }
        if !branchPullRequests.isEmpty { branchPullRequests = [:] }
        settledChecks = []
        lastRefresh = nil
        pausedUntil = nil
        actionNotice = nil
    }

    /// `origin` when it names a repository on `host`, else the first remote that does, with that repository.
    static func remote(in remotes: [RemoteInfo], host: String) -> (name: String, repository: HostedRepository)? {
        let host = host.lowercased()
        let ordered = remotes.filter { $0.name == "origin" } + remotes.filter { $0.name != "origin" }
        return ordered.lazy
            .compactMap { remote in GitHubClient.repository(fromRemoteURL: remote.url).map { (remote.name, $0) } }
            .first { $0.1.host == host }
    }

    /// The client, the repository and its remote while connected: the PR detail loads and acts through them.
    var api: (client: GitHubClient, repository: HostedRepository, remote: String)? {
        guard case .connected = connection, let client, let identity else { return nil }
        return (client, identity.repository, identity.remote)
    }

    /// Reloads the lists now (after an action changed a pull request), unless a rate limit holds.
    func refreshNow() {
        guard case .connected = connection else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    /// Reads the profile's token (the Keychain, off the main actor) and builds its client; nil without a usable
    /// token. The token stays inside the client.
    @concurrent
    private nonisolated static func makeClient(profile: Profile, host: String) async -> GitHubClient? {
        guard let token = await GitHubTokens.token(for: profile) else { return nil }
        return try? GitHubClient(host: host, token: token)
    }

    // MARK: Loading

    /// Reloads the four lists (rows already shown stay until the new ones are in), then the checks of their pull
    /// requests. Skipped while a rate limit holds.
    private func refresh() async {
        guard case .connected(let repository) = connection, let client, let remote = identity?.remote else { return }
        if let pausedUntil, pausedUntil > .now { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let (results, heads) = await Self.fetchLists(client, repository, remote: remote)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        // A failed All open keeps the badges it last gave.
        if let heads, heads != branchPullRequests { branchPullRequests = heads }
        var lists = self.lists
        for (list, result) in results {
            switch result {
            case .success(let rows):
                lists[list] = ListState(rows: rows, error: nil)
            case .failure(let error):
                lists[list, default: ListState()].error = listError(error)
            }
        }
        if lists != self.lists { self.lists = lists }
        // `content prs stub/stub mine:1 reviewRequested:0 allOpen:1 assigned:1` (`error` for a failed list).
        UITiming.content("prs \(repository.fullName) " + List.allCases.map { list in
            let state = lists[list]
            return "\(list.rawValue):" + (state?.error != nil ? "error" : "\(state?.rows?.count ?? 0)")
        }.joined(separator: " "))
        await refreshChecks(client, repository, generation: generation)
        // Only a refresh that ran to its end counts: one cut short (the PRs tab showing restarts `watch`) runs again.
        if generation == refreshGeneration, !Task.isCancelled { lastRefresh = .now }
    }

    private func refreshChecks(_ client: GitHubClient, _ repository: HostedRepository, generation: Int) async {
        var commits: [String] = []
        let rows = [List.mine, .reviewRequested, .allOpen].flatMap { lists[$0]?.rows ?? [] }
        for sha in rows.compactMap(\.headSHA) where !commits.contains(sha) && !settledChecks.contains(sha) {
            commits.append(sha)
            if commits.count == Self.maxCheckedCommits { break }
        }
        guard !commits.isEmpty else { return }
        let results = await Self.fetchChecks(client, repository, commits: commits)
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        var checks = self.checks
        for (sha, result) in results {
            switch result {
            case .success(let state):
                checks[sha] = state
                if state == .success { settledChecks.insert(sha) }
            case .failure(let error):
                // A token without the checks permission reads lists but not check runs: the rows show no state. A
                // rate limit still pauses the refreshes (`listError`).
                _ = listError(error)
                Self.logger.notice("check runs unreadable: \(String(describing: error), privacy: .public)")
            }
        }
        if checks != self.checks { self.checks = checks }
        // `content prs checks 1/1 success:1 failure:0 pending:0`: commits read, then their states.
        UITiming.content("prs checks \(results.count)/\(commits.count) " + [ChecksState.success, .failure, .pending]
            .map { state in "\(state):\(commits.count { checks[$0] == state })" }.joined(separator: " "))
    }

    /// The card's text for a failed read; a rate limit also pauses the refreshes until it ends.
    private func listError(_ error: any Error) -> ListError {
        switch error {
        case GitHubError.unauthorized:
            return ListError(message: "GitHub refused the token (revoked or expired).", reconnect: true)
        case GitHubError.rateLimited(let resetsAt):
            pausedUntil = resetsAt ?? Date.now.addingTimeInterval(60)
            return ListError(message: "\(error) Histq tries again then.", reconnect: false)
        case GitHubError.secondaryRateLimited(let seconds):
            pausedUntil = Date.now.addingTimeInterval(TimeInterval(seconds ?? 60))
            return ListError(message: String(describing: error), reconnect: false)
        case let error as GitHubError:
            return ListError(message: String(describing: error), reconnect: false)
        default:
            return ListError(message: error.localizedDescription, reconnect: false)
        }
    }

    /// The four lists at once. My PRs and Review requested come from the search API (issue-shaped hits); the hits
    /// that All open has take its head commit (for the checks) and draft flag. Also All open's badges by remote branch
    /// (`branchPullRequests`), nil when it failed.
    @concurrent
    private nonisolated static func fetchLists(_ client: GitHubClient, _ repository: HostedRepository, remote: String)
        async -> (lists: [List: Result<[HostedRow], any Error>], heads: [String: RefBadge.PullRequest]?)
    {
        async let open = capture { try await client.pullRequests(in: repository, state: .open) }
        async let mine = capture { try await client.myOpenPullRequests(in: repository) }
        async let review = capture { try await client.reviewRequestedPullRequests(in: repository) }
        async let assigned = capture { try await client.assignedOpenIssues(in: repository) }
        let (pulls, mineHits, reviewHits, issueHits) = await (open, mine, review, assigned)
        let byNumber = Dictionary(((try? pulls.get()) ?? []).map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        let lists: [List: Result<[HostedRow], any Error>] = [
            .allOpen: pulls.map { $0.map(HostedRow.init(pull:)) },
            .mine: mineHits.map { $0.map { HostedRow(searchHit: $0, pull: byNumber[$0.number]) } },
            .reviewRequested: reviewHits.map { $0.map { HostedRow(searchHit: $0, pull: byNumber[$0.number]) } },
            .assigned: issueHits.map { $0.filter { !$0.isPullRequest }.map { HostedRow(searchHit: $0, pull: nil) } },
        ]
        return (lists, (try? pulls.get()).map { branchPullRequests($0, repository: repository, remote: remote) })
    }

    /// The badges of `pulls` by remote branch: only heads whose `owner:branch` label names the repository's owner (a
    /// fork's head is another repository's branch). When two pull requests share a head, the lowest number wins.
    nonisolated static func branchPullRequests(
        _ pulls: [GitHubPullRequest], repository: HostedRepository, remote: String
    ) -> [String: RefBadge.PullRequest] {
        var result: [String: RefBadge.PullRequest] = [:]
        for pull in pulls.sorted(by: { $0.number < $1.number }) where pull.state == "open" {
            guard let label = pull.head.label, let colon = label.firstIndex(of: ":"),
                  label[..<colon].lowercased() == repository.owner.lowercased()
            else { continue }
            let branch = "\(remote)/\(pull.head.ref)"
            if result[branch] == nil {
                result[branch] = RefBadge.PullRequest(number: pull.number, isDraft: pull.draft ?? false)
            }
        }
        return result
    }

    /// The checks state of each commit (nil: no check runs).
    @concurrent
    private nonisolated static func fetchChecks(
        _ client: GitHubClient, _ repository: HostedRepository, commits: [String]
    ) async -> [String: Result<ChecksState?, any Error>] {
        await withTaskGroup(of: (String, Result<ChecksState?, any Error>).self) { group in
            for sha in commits {
                group.addTask {
                    (sha, await capture { ChecksState(try await client.checkRuns(for: sha, in: repository)) })
                }
            }
            var results: [String: Result<ChecksState?, any Error>] = [:]
            for await (sha, result) in group { results[sha] = result }
            return results
        }
    }

    private nonisolated static func capture<T>(_ body: () async throws -> T) async -> Result<T, any Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }
}
