// A pull request in panel2, laid out like GitHub's page, each part in its own card: the header (back, title, number,
// state pill, "author wants to merge N commits into base from head", the tabs), then the selected tab: Conversation
// (the description, comments and reviews in one `GitHubHTMLView`, the comment and review box, and a side column with
// the actions, reviewers, assignees and labels), Commits, Files changed (the file list and the selected file's patch in
// a read-only `DiffLineTable`, parsed from GitHub's `patch` with git's diff parser, so no local git is needed) and
// Checks. The row click shows the header and skeleton cards in the same frame (`PlaceholderCard`); everything loads
// off the main actor in one go (`PullRequestDetailModel`). The actions call GitHub through the tab's `GitHubStore`
// client; Merge and Close/Reopen ask first; Checkout locally is a repo write (`RepoSession.Write.checkoutPullRequest`).
import AppKit
import HistqCore
import SwiftUI

// MARK: - Model

/// The detail's tabs.
enum PRTab: String, CaseIterable, Hashable, Sendable {
    case conversation, commits, files, checks

    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .commits: "Commits"
        case .files: "Files changed"
        case .checks: "Checks"
        }
    }

    var systemImage: String {
        switch self {
        case .conversation: "text.bubble"
        case .commits: "point.3.connected.trianglepath.dotted"
        case .files: "doc.on.doc"
        case .checks: "checkmark.seal"
        }
    }
}

/// A changed file of the pull request, with its rows built off the main actor; no section when GitHub sent no patch
/// (a binary file, or a diff too large for the API).
struct PRFile: Identifiable, Sendable {
    let file: GitHubPullRequestFile
    let change: FileChange
    let section: DiffSection?

    var id: String { file.filename }
}

/// A reviewer and where their review stands: requested (no review yet), or their latest review's state.
struct PRReviewer: Identifiable, Sendable {
    let login: String
    /// nil while the review is only requested.
    let state: String?

    var id: String { login }
}

/// Everything the detail shows, read in one load. Commits, files and checks may fail on their own (a token without
/// the checks permission still reads the pull request): their tab then says why.
struct PullRequestDetail: Sendable {
    let loadID: Int
    let pull: GitHubPullRequest
    let timelineCount: Int
    /// The Conversation's page: the description, then comments and reviews by date (`PRTimeline`).
    let timelineHTML: String
    let reviewers: [PRReviewer]
    let commits: Loadable<[GitHubCommit]>
    let files: Loadable<[PRFile]>
    let checks: Loadable<[GitHubCheckRun]>

    var isMerged: Bool { pull.mergedAt != nil || pull.merged == true }
    var isOpen: Bool { pull.state == "open" }
}

/// A GitHub action of the detail.
enum PullRequestAction: Equatable, Sendable {
    /// `sha`: the head the user saw when confirming; GitHub refuses the merge once the head moved.
    case merge(HostedMergeMethod, sha: String)
    case review(HostedReviewEvent, body: String)
    case comment(String)
    case setOpen(Bool)

    var progressTitle: String {
        switch self {
        case .merge: "Merging…"
        case .review: "Submitting the review…"
        case .comment: "Commenting…"
        case .setOpen(let open): open ? "Reopening…" : "Closing…"
        }
    }

    var failureTitle: String {
        switch self {
        case .merge: "Merge failed"
        case .review: "The review was not submitted"
        case .comment: "The comment was not posted"
        case .setOpen(let open): open ? "Reopen failed" : "Close failed"
        }
    }

    /// The failure's title when another pull request shows by the time it returns: it names `number`.
    func failureTitle(of number: Int) -> String {
        switch self {
        case .merge: "Merge of #\(number) failed"
        case .review: "The review of #\(number) was not submitted"
        case .comment: "The comment on #\(number) was not posted"
        case .setOpen(let open): open ? "Reopen of #\(number) failed" : "Close of #\(number) failed"
        }
    }

    /// The timing log's word (`content pr 1 action merge ok`).
    var timingName: String {
        switch self {
        case .merge(let method, _): "merge-\(method.rawValue)"
        case .review(let event, _): "review-\(event.rawValue.lowercased())"
        case .comment: "comment"
        case .setOpen(let open): open ? "reopen" : "close"
        }
    }
}

extension HostedMergeMethod {
    static let all: [HostedMergeMethod] = [.merge, .squash, .rebase]

    var title: String {
        switch self {
        case .merge: "Merge commit"
        case .squash: "Squash"
        case .rebase: "Rebase"
        }
    }

    var buttonTitle: String {
        switch self {
        case .merge: "Merge"
        case .squash: "Squash and Merge"
        case .rebase: "Rebase and Merge"
        }
    }
}

extension HostedReviewEvent {
    static let all: [HostedReviewEvent] = [.approve, .requestChanges, .comment]

    var title: String {
        switch self {
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        case .comment: "Comment"
        }
    }
}

/// The open pull request of a repo tab: its load, the selected tab and file, the comment box and the running action.
/// `RepoSession.selectHosted` starts a load in the click's call (`state` is `.loading` when it returns); a newer
/// select or `close` drops an older load's answer.
@Observable
@MainActor
final class PullRequestDetailModel {
    enum Composer: String, CaseIterable, Hashable {
        case comment, review

        var title: String {
            switch self {
            case .comment: "Comment"
            case .review: "Review"
            }
        }
    }

    private(set) var number: Int?
    private(set) var state: Loadable<PullRequestDetail> = .idle
    var tab: PRTab = .conversation
    /// The Files changed tab's file (its `filename`).
    var selectedFile: String?
    var composer: Composer = .comment
    var draft = ""
    var reviewEvent: HostedReviewEvent = .approve
    var mergeMethod: HostedMergeMethod = .merge
    /// The actions running on GitHub, by pull request: one at a time for each. An action belongs to the pull request it
    /// started on, not to the detail, which may show another one by the time it returns.
    private(set) var busy: [Int: PullRequestAction] = [:]
    /// The last action's failure (or a failed reload after it), above the tabs until dismissed or the next action.
    var actionError: String?

    /// The shown pull request's running action.
    var running: PullRequestAction? { number.flatMap { busy[$0] } }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadCount = 0

    /// DEBUG `-HistqPRTab commits|files|checks`: the tab a pull request opens on (QA shots of each tab).
    private static let launchTab = AppState.launchFlag("-HistqPRTab").flatMap(PRTab.init(rawValue:))
    #if DEBUG
    /// DEBUG `-HistqPRAction comment|approve|request-changes|merge|merge-stale|merge-stale-closed|close|reopen`: runs
    /// that action once, on the first load, without its confirmation (the stub answers it), so a launch exercises the
    /// action path and its reload. Only with `-HistqGitHubStub YES`: never an unconfirmed action on a real account.
    private static var launchAction: PullRequestAction? = switch GitHubStub.isEnabled
        ? AppState.launchFlag("-HistqPRAction") : nil {
    case "comment": .comment("QA comment")
    case "approve": .review(.approve, body: "")
    case "request-changes": .review(.requestChanges, body: "QA change request")
    case "merge": .merge(.squash, sha: GitHubStub.headSHA)
    // A head the stub's PR #1 no longer has: the stub answers 409, as GitHub does after a push.
    case "merge-stale", "merge-stale-closed": .merge(.squash, sha: GitHubStub.staleSHA)
    case "close": .setOpen(false)
    case "reopen": .setOpen(true)
    default: nil
    }
    /// `merge-stale-closed`: the detail closes while the merge runs, so its failure is another detail's (the PRs tab's
    /// notice).
    private static let closesAfterLaunchAction = AppState.launchFlag("-HistqPRAction") == "merge-stale-closed"
    #endif

    /// Loads pull request `number`; `quiet` keeps the shown detail until the new one is in (after an action).
    func load(_ number: Int, github: GitHubStore, quiet: Bool = false) {
        task?.cancel()
        generation &+= 1
        if number != self.number {
            // Another pull request: its own tab, file and box. The same one opened again keeps them (and the draft).
            tab = Self.launchTab ?? .conversation
            selectedFile = nil
            composer = .comment
            draft = ""
            reviewEvent = .approve
            actionError = nil
        }
        self.number = number
        if !quiet || state.value == nil { state = .loading }
        guard let api = github.api else {
            state = .failed("GitHub is not connected for this tab: connect it in Settings › Integrations.")
            return
        }
        let generation = generation
        loadCount &+= 1
        let loadID = loadCount
        task = Task { [weak self] in
            let result = await Self.fetch(api.client, api.repository, number: number, loadID: loadID)
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            switch result {
            case .success(let detail):
                state = .loaded(detail)
                if quiet { UITiming.content("pr \(number) reloaded") }
                #if DEBUG
                if let action = Self.launchAction {
                    Self.launchAction = nil
                    perform(action, on: number, github: github)
                    if Self.closesAfterLaunchAction { close() }
                }
                #endif
                let names = detail.files.value?.map(\.id) ?? []
                if selectedFile.map({ !names.contains($0) }) ?? true { selectedFile = names.first }
            case .failure(let error):
                if quiet, state.value != nil {
                    actionError = "Could not reload the pull request: \(Self.message(for: error))"
                } else {
                    state = .failed(Self.message(for: error))
                }
            }
        }
    }

    /// The detail closed (Esc, another selection): an answer still on its way is dropped.
    func close() {
        task?.cancel()
        task = nil
        generation &+= 1
        state = .idle
    }

    /// Runs `action` on pull request `number` (the one whose detail the user acted on), then reloads it and the PRs
    /// tab's lists. A failure shows above the tabs while that pull request shows; otherwise it names the number in
    /// the PRs tab (`GitHubStore.actionNotice`), since the shown detail is another one's.
    func perform(_ action: PullRequestAction, on number: Int, github: GitHubStore) {
        guard busy[number] == nil else { return }
        guard let api = github.api else {
            actionError = "GitHub is not connected for this tab."
            return
        }
        busy[number] = action
        if self.number == number { actionError = nil }
        Task { [weak self] in
            let error = await Self.run(action, api.client, api.repository, number: number)
            guard let self else { return }
            busy[number] = nil
            UITiming.content("pr \(number) action \(action.timingName) \(error == nil ? "ok" : "failed")")
            let showing = isShowing(number)
            if let error {
                UITiming.content("pr \(number) action error \(Self.message(for: error))")
                if showing {
                    actionError = "\(action.failureTitle): \(Self.message(for: error))"
                } else {
                    github.actionNotice = "\(action.failureTitle(of: number)): \(Self.message(for: error))"
                }
                // The head moved since the user reviewed it: show the new one, so they review it before merging.
                if case GitHubError.headChanged = error {
                    github.refreshNow()
                    if showing { load(number, github: github, quiet: true) }
                }
                return
            }
            switch action {
            case .comment, .review: if self.number == number { draft = "" }
            case .merge, .setOpen: break
            }
            github.refreshNow()
            if showing { load(number, github: github, quiet: true) }
        }
    }

    /// Whether the detail shows pull request `number` (loading or loaded), not another one or nothing (closed).
    private func isShowing(_ number: Int) -> Bool {
        guard self.number == number else { return false }
        if case .idle = state { return false }
        return true
    }

    @concurrent
    private nonisolated static func fetch(
        _ client: GitHubClient, _ repository: HostedRepository, number: Int, loadID: Int
    ) async -> Result<PullRequestDetail, any Error> {
        async let pullRequest = client.pullRequest(number, in: repository)
        async let comments = client.comments(on: number, in: repository)
        async let reviews = client.reviews(of: number, in: repository)
        async let commits = part { try await client.pullRequestCommits(number, in: repository) }
        async let files = part { try await client.pullRequestFiles(number, in: repository) }
        do {
            let pull = try await pullRequest
            async let checks = part { try await client.checkRuns(for: pull.head.sha, in: repository) }
            let (comments, reviews) = try await (comments, reviews)
            let fileList: Loadable<[PRFile]> = switch await files {
            case .loaded(let files): .loaded(files.map(prFile))
            case .failed(let message): .failed(message)
            case .idle, .loading: .idle
            }
            return .success(PullRequestDetail(
                loadID: loadID, pull: pull, timelineCount: comments.count + reviews.count { $0.state != "PENDING" },
                timelineHTML: PRTimeline.html(pull: pull, comments: comments, reviews: reviews),
                reviewers: reviewers(pull, reviews), commits: await commits, files: fileList, checks: await checks))
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func part<T: Sendable>(_ body: () async throws -> T) async -> Loadable<T> {
        do {
            return .loaded(try await body())
        } catch {
            return .failed(message(for: error))
        }
    }

    private nonisolated static func prFile(_ file: GitHubPullRequestFile) -> PRFile {
        let letter: Character = switch file.status {
        case "added": "A"
        case "removed": "D"
        case "renamed": "R"
        case "copied": "C"
        default: "M"
        }
        let section = file.diff.flatMap {
            DiffSection(side: .commit, diff: $0, full: nil, language: LanguageTable.language(forPath: file.filename))
        }
        return PRFile(file: file, change: FileChange(letter: letter, path: file.filename,
                                                     originalPath: file.previousFilename), section: section)
    }

    /// The requested reviewers, then everyone who reviewed with their latest state (a later comment-only review does
    /// not hide an approval or a change request, as on GitHub).
    private nonisolated static func reviewers(_ pull: GitHubPullRequest, _ reviews: [GitHubReview]) -> [PRReviewer] {
        var latest: [String: String] = [:]
        var order: [String] = []
        for review in reviews where review.state != "PENDING" {
            guard let login = review.user?.login else { continue }
            if latest[login] == nil { order.append(login) }
            if review.state != "COMMENTED" || latest[login] == nil { latest[login] = review.state }
        }
        let requested = (pull.requestedReviewers ?? []).map(\.login).filter { latest[$0] == nil }
        return requested.map { PRReviewer(login: $0, state: nil) } + order.map { PRReviewer(login: $0, state: latest[$0]) }
    }

    @concurrent
    private nonisolated static func run(
        _ action: PullRequestAction, _ client: GitHubClient, _ repository: HostedRepository, number: Int
    ) async -> (any Error)? {
        do {
            switch action {
            case .merge(let method, let sha): try await client.merge(number, in: repository, method: method, sha: sha)
            case .review(let event, let body):
                _ = try await client.review(number, in: repository, event: event, body: body.isEmpty ? nil : body)
            case .comment(let body): _ = try await client.comment(on: number, in: repository, body: body)
            case .setOpen(let open): try await client.setOpen(open, number: number, in: repository)
            }
            return nil
        } catch {
            return error
        }
    }

    nonisolated static func message(for error: any Error) -> String {
        switch error {
        case GitHubError.unauthorized:
            "GitHub refused the token (revoked or expired). Reconnect in Settings › Integrations."
        case let error as GitHubError:
            String(describing: error)
        default:
            error.localizedDescription
        }
    }
}

// MARK: - Timeline page

/// The Conversation's HTML: the description and every comment and review, oldest first, each in a bordered box with
/// its author, what they did and when. Only GitHub's `body_html` is inserted as is; every other value is escaped.
enum PRTimeline {
    private struct Entry {
        let date: Date?
        let html: String
    }

    nonisolated static func html(pull: GitHubPullRequest, comments: [GitHubComment], reviews: [GitHubReview]) -> String {
        var entries = comments.map { comment in
            Entry(date: comment.createdAt, html: item(
                author: comment.user?.login, action: "commented", badge: nil, date: comment.createdAt,
                bodyHTML: bodyHTML(comment.bodyHTML, comment.body), emptyText: nil))
        }
        for review in reviews where review.state != "PENDING" {
            let (action, badge): (String, String?) = switch review.state {
            case "APPROVED": ("approved these changes", "approved")
            case "CHANGES_REQUESTED": ("requested changes", "changes")
            case "DISMISSED": ("reviewed (dismissed)", nil)
            default: ("reviewed", nil)
            }
            entries.append(Entry(date: review.submittedAt, html: item(
                author: review.user?.login, action: action, badge: badge, date: review.submittedAt,
                bodyHTML: bodyHTML(review.bodyHTML, review.body), emptyText: nil)))
        }
        // Stable for equal dates: comments before reviews, as appended.
        let sorted = entries.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?) where x != y: x < y
            default: a.offset < b.offset
            }
        }.map(\.element.html)
        let description = item(
            author: pull.user?.login, action: "opened this pull request", badge: nil, date: pull.createdAt,
            bodyHTML: bodyHTML(pull.bodyHTML, pull.body), emptyText: "No description provided.")
        return ([description] + sorted).joined()
    }

    /// GitHub's HTML, or (when an answer has none) the markdown source as escaped plain text. The issue detail's
    /// timeline uses it too.
    nonisolated static func bodyHTML(_ html: String?, _ markdown: String?) -> String? {
        if let html, !html.isEmpty { return html }
        guard let markdown, !markdown.isEmpty else { return nil }
        return "<p class=\"plain\">\(GitHubHTML.escape(markdown))</p>"
    }

    nonisolated static func item(
        author: String?, action: String, badge: String?, date: Date?, bodyHTML: String?, emptyText: String?
    ) -> String {
        let who = GitHubHTML.escape(author ?? "ghost")
        let what = badge.map { "<span class=\"badge \($0)\">\(GitHubHTML.escape(action))</span>" }
            ?? GitHubHTML.escape(action)
        let when = date.map { "<span class=\"date\">\(GitHubHTML.escape($0.formatted(date: .abbreviated, time: .shortened)))</span>" } ?? ""
        let body: String
        if let bodyHTML, !bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = "<div class=\"body\">\(bodyHTML)</div>"
        } else if let emptyText {
            body = "<div class=\"body empty\">\(GitHubHTML.escape(emptyText))</div>"
        } else {
            body = ""
        }
        return "<section class=\"item\"><div class=\"head\"><b>\(who)</b> \(what)\(when)</div>\(body)</section>"
    }
}

// MARK: - Views

/// Panel2 while a pull request is open: the header card at once, then the tab's cards (skeletons until loaded).
struct PRDetailView: View {
    let session: RepoSession
    let number: Int
    @Environment(WindowModel.self) private var model

    var body: some View {
        let detail = session.pullDetail
        VStack(spacing: SectionCardMetrics.spacing) {
            PRHeaderCard(session: session, number: number)
            if let error = detail.actionError {
                PRActionErrorCard(message: error) { detail.actionError = nil }
                    .onAppear { UITiming.content("pr \(number) action-error shown") }
            }
            Group {
                switch detail.state {
                case .idle, .loading:
                    PlaceholderCard(
                        token: session.hostedToken, detail: "pr \(number)",
                        isCurrent: { [model, session, number] in
                            model.selectedSession === session && session.openHosted == .pullRequest(number)
                        }
                    ) {
                        PRSkeleton()
                    }
                case .loaded(let value):
                    PRContent(session: session, detail: value)
                        .onAppear { UITiming.content("pr \(number)") }
                case .failed(let message):
                    DiffNoticeCard(title: "Pull request", systemImage: "exclamationmark.triangle", message: message)
                        .onAppear { UITiming.content("pr \(number) failed") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Back, the title and number, the state pill and Open on GitHub; the "wants to merge" line; the tabs with their
/// counts. The title comes from the PRs tab's row until the pull request is in.
private struct PRHeaderCard: View {
    let session: RepoSession
    let number: Int

    var body: some View {
        @Bindable var detail = session.pullDetail
        let value = detail.state.value
        let title = value?.pull.title ?? session.github.row(for: .pullRequest(number))?.title
        SectionCard(nil, contentPadding: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        session.closeFile()
                    } label: {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(RowIconButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("Back to the Graph (Esc)")
                    .accessibilityLabel("Back to the graph")
                    .padding(.leading, 4)
                    Image(systemName: "arrow.triangle.pull")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    if let title {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(title)
                    } else {
                        SkeletonLine(width: 180, height: 12)
                    }
                    Text("#\(number)")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let value {
                        PRStatePill(detail: value)
                        Button {
                            GitHubLinks.open(value.pull.htmlURL)
                        } label: {
                            Image(systemName: "safari")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(RowIconButtonStyle())
                        .help("Open on GitHub")
                        .accessibilityLabel("Open on GitHub")
                    } else {
                        SkeletonLine(width: 56, height: 20)
                    }
                }
                .frame(height: 32)
                Group {
                    if let value {
                        summary(value)
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        SkeletonLine(width: 260, height: 11)
                    }
                }
                .padding(.leading, 8)
                CapsuleTabs(selection: $detail.tab, tabs: PRTab.allCases, title: { tab in tabTitle(tab, value) },
                            compact: true)
                    .fixedSize()
                    .padding(.leading, 4)
            }
        }
    }

    /// "stub wants to merge 2 commits into main from feature" (merged: "merged"; closed: "wanted to merge").
    private func summary(_ value: PullRequestDetail) -> Text {
        let pull = value.pull
        let count = pull.commits ?? value.commits.value?.count ?? 0
        let verb = value.isMerged ? "merged" : value.isOpen ? "wants to merge" : "wanted to merge"
        return Text(pull.user?.login ?? "ghost").fontWeight(.semibold)
            + Text(" \(verb) \(count) \(count == 1 ? "commit" : "commits") into ")
            + Text(pull.base.ref).monospaced()
            + Text(" from ")
            + Text(pull.head.label ?? pull.head.ref).monospaced()
    }

    private func tabTitle(_ tab: PRTab, _ value: PullRequestDetail?) -> Text {
        let count: Int? = switch tab {
        case .conversation: value?.timelineCount
        case .commits: value?.commits.value?.count
        case .files: value?.files.value?.count
        case .checks: value?.checks.value?.count
        }
        guard let count else { return Text(tab.title) }
        return Text(tab.title) + Text(" \(count)").monospacedDigit()
    }
}

/// Open (green), Draft, Merged (the brand blue) or Closed (red), as on GitHub.
private struct PRStatePill: View {
    let detail: PullRequestDetail

    var body: some View {
        let (title, symbol, fill, text): (String, String, Color, Color) =
            if detail.isMerged {
                ("Merged", "arrow.triangle.merge", Palette.primaryFill, Palette.onAccent)
            } else if !detail.isOpen {
                ("Closed", "xmark.circle", Color(nsColor: Palette.diffRemovedFill), Color(nsColor: Palette.diffRemovedSign))
            } else if detail.pull.draft == true {
                ("Draft", "circle.dashed", Palette.inputSurface, .secondary)
            } else {
                ("Open", "arrow.triangle.pull", Color(nsColor: Palette.diffAddedFill), Color(nsColor: Palette.diffAddedSign))
            }
        Label(title, systemImage: symbol)
            .font(.settingsCaption.weight(.semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(fill))
            .accessibilityLabel("State: \(title)")
    }
}

/// A failed action, with a close button (the issue detail's too).
struct PRActionErrorCard: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        SectionCard(nil, contentPadding: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: Palette.diffRemovedSign))
                    .padding(.leading, 4)
                    .accessibilityHidden(true)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(RowIconButtonStyle())
                .help("Dismiss")
                .accessibilityLabel("Dismiss the error")
            }
        }
    }
}

/// The loaded detail's selected tab.
private struct PRContent: View {
    let session: RepoSession
    let detail: PullRequestDetail

    var body: some View {
        let number = detail.pull.number
        switch session.pullDetail.tab {
        case .conversation:
            PRConversationTab(session: session, detail: detail)
                .onAppear { UITiming.content("pr \(number) conversation \(detail.timelineCount)") }
        case .commits:
            PRCommitsTab(commits: detail.commits)
                .onAppear { UITiming.content("pr \(number) commits \(Self.count(detail.commits))") }
        case .files:
            PRFilesTab(session: session, detail: detail)
                .onAppear { UITiming.content("pr \(number) files \(Self.count(detail.files))") }
        case .checks:
            PRChecksTab(checks: detail.checks)
                .onAppear { UITiming.content("pr \(number) checks \(Self.count(detail.checks))") }
        }
    }

    private static func count<T>(_ part: Loadable<[T]>) -> String {
        part.value.map { "\($0.count)" } ?? "failed"
    }
}

// MARK: Conversation

/// The timeline card and the comment box, with the side column on the right (below them when panel2 is narrow).
private struct PRConversationTab: View {
    let session: RepoSession
    let detail: PullRequestDetail

    private static let sideWidth: CGFloat = 220
    /// Narrower than this, the side column goes under the timeline.
    private static let wideEnough: CGFloat = 560

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.wideEnough {
                HStack(alignment: .top, spacing: SectionCardMetrics.spacing) {
                    main
                    ScrollView {
                        PRSideColumn(session: session, detail: detail)
                    }
                    .scrollIndicators(.never)
                    .frame(width: Self.sideWidth)
                }
            } else {
                VStack(spacing: SectionCardMetrics.spacing) {
                    main
                    ScrollView {
                        PRSideColumn(session: session, detail: detail)
                    }
                    .frame(maxHeight: min(240, proxy.size.height / 2))
                }
            }
        }
    }

    private var main: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            SectionCard("Conversation", systemImage: "text.bubble", count: detail.timelineCount) {
                GitHubHTMLView(html: detail.timelineHTML) { [number = detail.pull.number] in
                    UITiming.content("pr \(number) conversation html")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            PRComposerCard(session: session, detail: detail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The comment box: a plain comment, or a review (approve, request changes, comment) with its body.
private struct PRComposerCard: View {
    let session: RepoSession
    let detail: PullRequestDetail

    var body: some View {
        @Bindable var model = session.pullDetail
        let isReview = model.composer == .review
        SectionCard(isReview ? "Review" : "Comment", systemImage: isReview ? "checkmark.bubble" : "square.and.pencil") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $model.draft)
                    .font(.body)
                    .settingsTextEditor()
                    .frame(height: 64)
                    .overlay(alignment: .topLeading) {
                        if model.draft.isEmpty {
                            Text(placeholder(model))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 8) {
                    if isReview {
                        CapsuleMenuPicker(label: "Review", selection: $model.reviewEvent,
                                          title: Text(model.reviewEvent.title)) {
                            ForEach(HostedReviewEvent.all, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        submit(model)
                    } label: {
                        HStack(spacing: 6) {
                            if isBusy(model) { ProgressView().controlSize(.mini) }
                            Text(isReview ? "Submit Review" : "Comment")
                        }
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .disabled(!canSubmit(model))
                    .help(isReview && model.reviewEvent != .approve && trimmed(model).isEmpty
                          ? "A review that requests changes or comments needs a text" : "")
                }
            }
        } accessory: {
            CapsuleTabs(selection: $model.composer, tabs: PullRequestDetailModel.Composer.allCases,
                        title: { Text($0.title) }, compact: true)
                .fixedSize()
        }
    }

    private func placeholder(_ model: PullRequestDetailModel) -> String {
        guard model.composer == .review else { return "Leave a comment" }
        return model.reviewEvent == .approve ? "Approve, with an optional comment" : "Say what to change"
    }

    private func trimmed(_ model: PullRequestDetailModel) -> String {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isBusy(_ model: PullRequestDetailModel) -> Bool {
        switch model.running {
        case .comment, .review: true
        default: false
        }
    }

    private func canSubmit(_ model: PullRequestDetailModel) -> Bool {
        guard model.running == nil else { return false }
        // GitHub requires a body for a change request and a comment review; an approval may have none.
        if model.composer == .review, model.reviewEvent == .approve { return true }
        return !trimmed(model).isEmpty
    }

    private func submit(_ model: PullRequestDetailModel) {
        guard canSubmit(model) else { return }
        let body = trimmed(model)
        let action: PullRequestAction = model.composer == .review
            ? .review(model.reviewEvent, body: body) : .comment(body)
        guard let number = model.number else { return }
        model.perform(action, on: number, github: session.github)
    }
}

/// The right column: the actions, then reviewers, assignees and labels, each in its own card.
private struct PRSideColumn: View {
    let session: RepoSession
    let detail: PullRequestDetail

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            PRActionsCard(session: session, detail: detail)
            SectionCard("Reviewers", systemImage: "person.2", count: detail.reviewers.count) {
                if detail.reviewers.isEmpty {
                    PRSideEmpty(text: "No reviews")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(detail.reviewers) { reviewer in
                            PRPersonRow(login: reviewer.login, state: reviewer.state, showsState: true)
                        }
                    }
                }
            }
            SectionCard("Assignees", systemImage: "person.crop.circle", count: detail.pull.assignees?.count ?? 0) {
                let assignees = detail.pull.assignees ?? []
                if assignees.isEmpty {
                    PRSideEmpty(text: "No one assigned")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(assignees, id: \.id) { PRPersonRow(login: $0.login, state: nil, showsState: false) }
                    }
                }
            }
            SectionCard("Labels", systemImage: "tag", count: detail.pull.labels?.count ?? 0) {
                let labels = detail.pull.labels ?? []
                if labels.isEmpty {
                    PRSideEmpty(text: "None yet")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(labels, id: \.name) { PRLabelChip(label: $0) }
                    }
                }
            }
        }
    }
}

/// Merge (method, then a confirmation), Checkout locally, Close or Reopen (confirmed), and the running action.
private struct PRActionsCard: View {
    let session: RepoSession
    let detail: PullRequestDetail
    @Environment(WindowModel.self) private var model

    var body: some View {
        @Bindable var pullDetail = session.pullDetail
        let pull = detail.pull
        let busy = pullDetail.busy[detail.pull.number]
        SectionCard("Actions", systemImage: "bolt") {
            VStack(alignment: .leading, spacing: 10) {
                if detail.isMerged {
                    Label("Merged into \(pull.base.ref)", systemImage: "arrow.triangle.merge")
                        .foregroundStyle(.secondary)
                } else if detail.isOpen {
                    Text(mergeNote)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        CapsuleMenuPicker(label: "Merge method", selection: $pullDetail.mergeMethod,
                                          title: Text(pullDetail.mergeMethod.title)) {
                            ForEach(HostedMergeMethod.all, id: \.self) { Text($0.title).tag($0) }
                        }
                        Button("Merge…") { confirmMerge(pullDetail.mergeMethod) }
                            .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                            .disabled(busy != nil || pull.draft == true || pull.mergeable == false)
                            .fixedSize()
                    }
                }
                Button("Checkout Locally") { checkout() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .help("Fetch pull/\(pull.number)/head into the branch pr/\(pull.number) and check it out")
                if !detail.isMerged {
                    Button(detail.isOpen ? "Close Pull Request…" : "Reopen Pull Request…") { confirmSetOpen(!detail.isOpen) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(busy != nil)
                }
                if let busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(busy.progressTitle)
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var mergeNote: String {
        let pull = detail.pull
        if pull.draft == true { return "A draft: mark it ready for review on GitHub to merge it." }
        return switch pull.mergeable {
        case true?: "No conflicts with \(pull.base.ref)."
        case false?: "Conflicts with \(pull.base.ref): resolve them before merging."
        case nil: "GitHub is still checking whether it merges cleanly."
        }
    }

    /// Merges the head this detail shows: the sha goes with the merge, so a push after this confirmation fails it.
    private func confirmMerge(_ method: HostedMergeMethod) {
        let pull = detail.pull
        let count = pull.commits ?? detail.commits.value?.count ?? 0
        let how = switch method {
        case .merge: "with a merge commit"
        case .squash: "squashed into one commit"
        case .rebase: "rebased onto \(pull.base.ref)"
        }
        model.presentModal(.confirmation(ModalConfirmation(
            title: "\(method.buttonTitle) #\(pull.number)?",
            message: "GitHub merges \(count) \(count == 1 ? "commit" : "commits") of \(pull.head.ref) into "
                + "\(pull.base.ref), \(how). Histq cannot undo a merge on GitHub.",
            button: method.buttonTitle, isDestructive: false,
            perform: { [session, sha = pull.head.sha, number = pull.number] in
                session.pullDetail.perform(.merge(method, sha: sha), on: number, github: session.github)
            })))
    }

    private func confirmSetOpen(_ open: Bool) {
        let number = detail.pull.number
        model.presentModal(.confirmation(ModalConfirmation(
            title: open ? "Reopen #\(number)?" : "Close #\(number)?",
            message: open
                ? "The pull request opens again on GitHub."
                : "The pull request closes on GitHub without merging; it can be reopened later.",
            button: open ? "Reopen" : "Close Pull Request", isDestructive: !open,
            perform: { [session] in session.pullDetail.perform(.setOpen(open), on: number, github: session.github) })))
    }

    /// Checks out `pr/<n>`: fetched from the repository's remote when it does not exist yet; checked out as is when it
    /// already points at the pull request's head; otherwise never overwritten (it may hold local commits), and the
    /// existing branch is offered instead.
    private func checkout() {
        let pull = detail.pull
        let branch = "pr/\(pull.number)"
        if let local = session.refs.value?.localBranches.first(where: { $0.name == branch }) {
            if local.commit == pull.head.sha {
                session.run(.checkoutBranch(branch), title: "Checkout \(branch)")
                return
            }
            model.presentModal(.confirmation(ModalConfirmation(
                title: "\(branch) already exists",
                message: "The local branch \(branch) points at another commit than the pull request's head "
                    + "(\(String(pull.head.sha.prefix(7)))). Histq does not overwrite it. Check out the existing branch?",
                button: "Checkout \(branch)", isDestructive: false,
                perform: { [session] in session.run(.checkoutBranch(branch), title: "Checkout \(branch)") })))
            return
        }
        guard let remote = session.github.api?.remote else {
            session.pullDetail.actionError = "No remote of this repository is on GitHub: nothing to fetch from."
            return
        }
        session.run(.checkoutPullRequest(number: pull.number, remote: remote), title: "Checkout #\(pull.number)")
    }
}

struct PRSideEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.settingsCaption)
            .foregroundStyle(.secondary)
    }
}

/// A reviewer or an assignee: the login, and for a reviewer the state of their review.
struct PRPersonRow: View {
    let login: String
    let state: String?
    let showsState: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(login)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if showsState {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .help(stateText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsState ? "\(login), \(stateText)" : login)
    }

    private var symbol: String {
        switch state {
        case "APPROVED": "checkmark"
        case "CHANGES_REQUESTED": "plus.forwardslash.minus"
        case nil: "circle"
        default: "text.bubble"
        }
    }

    private var tint: Color {
        switch state {
        case "APPROVED": Color(nsColor: Palette.diffAddedSign)
        case "CHANGES_REQUESTED": Color(nsColor: Palette.diffRemovedSign)
        default: .secondary
        }
    }

    private var stateText: String {
        switch state {
        case "APPROVED": "approved"
        case "CHANGES_REQUESTED": "requested changes"
        case "DISMISSED": "review dismissed"
        case nil: "review requested"
        default: "commented"
        }
    }
}

/// A label: its GitHub color as a dot (the label's own data), then its name.
struct PRLabelChip: View {
    let label: GitHubLabel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(label.name)
                .font(.settingsCaption)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Palette.tabFill))
        .help(label.description ?? label.name)
    }

    /// `RRGGBB` from GitHub; the secondary color when it is not one.
    private var dot: Color {
        guard let hex = label.color, hex.count == 6, let value = UInt32(hex, radix: 16) else { return .secondary }
        return Color(nsColor: NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                                      green: CGFloat((value >> 8) & 0xFF) / 255,
                                      blue: CGFloat(value & 0xFF) / 255, alpha: 1))
    }
}

// MARK: Commits

private struct PRCommitsTab: View {
    let commits: Loadable<[GitHubCommit]>

    var body: some View {
        switch commits {
        case .loaded(let commits):
            SectionCard("Commits", systemImage: PRTab.commits.systemImage, count: commits.count, contentPadding: 6) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(commits) { PRCommitRow(commit: $0) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        case .failed(let message):
            DiffNoticeCard(title: "Commits", systemImage: "exclamationmark.triangle", message: message)
        case .idle, .loading:
            DiffNoticeCard(title: "Commits", systemImage: "exclamationmark.triangle", message: "Not loaded.")
        }
    }
}

/// A commit: its subject, author and date, and its short id, which opens it on GitHub.
private struct PRCommitRow: View {
    let commit: GitHubCommit
    @State private var hovered = false

    var body: some View {
        let subject = commit.commit.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let author = commit.author?.login ?? commit.commit.author?.name ?? "ghost"
        HStack(spacing: 8) {
            Image(systemName: "circle.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Group {
                    if let date = commit.commit.author?.date {
                        Text(verbatim: "\(author) committed \(date.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text(verbatim: author)
                    }
                }
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                GitHubLinks.open(commit.htmlURL)
            } label: {
                Text(String(commit.sha.prefix(7)))
                    .font(.settingsCaption.monospaced())
            }
            .buttonStyle(RowTextButtonStyle())
            .help("Open this commit on GitHub")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? Palette.hoverFill : .clear))
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .help(commit.commit.message)
    }
}

// MARK: Files changed

/// The file list on the left, the selected file's patch on the right (read-only, `DiffMode.diff`).
private struct PRFilesTab: View {
    let session: RepoSession
    let detail: PullRequestDetail

    private static let listWidth: CGFloat = 240

    var body: some View {
        switch detail.files {
        case .loaded(let files) where files.isEmpty:
            DiffNoticeCard(title: "Files changed", systemImage: "checkmark.circle", message: "This pull request changes no file.")
        case .loaded(let files):
            HStack(alignment: .top, spacing: SectionCardMetrics.spacing) {
                SectionCard("Files", systemImage: PRTab.files.systemImage, count: files.count, contentPadding: 6) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(files) { file in
                                PRFileRow(file: file, selected: file.id == session.pullDetail.selectedFile) {
                                    session.pullDetail.selectedFile = file.id
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(width: Self.listWidth)
                .frame(maxHeight: .infinity)
                if let file = files.first(where: { $0.id == session.pullDetail.selectedFile }) ?? files.first {
                    diffCard(file)
                }
            }
        case .failed(let message):
            DiffNoticeCard(title: "Files changed", systemImage: "exclamationmark.triangle", message: message)
        case .idle, .loading:
            DiffNoticeCard(title: "Files changed", systemImage: "exclamationmark.triangle", message: "Not loaded.")
        }
    }

    @ViewBuilder private func diffCard(_ file: PRFile) -> some View {
        if let section = file.section, !section.rows(.diff).isEmpty {
            SectionCard(file.change.name, systemImage: file.change.systemImage, contentPadding: 0) {
                DiffLineTable(section: section, mode: .diff, loadID: detail.loadID,
                              onApply: { _, _, _ in }, onClose: { [session] in session.closeFile() })
                    .frame(maxHeight: .infinity)
            } accessory: {
                counts(file.file)
            }
            .id(file.id)
        } else {
            DiffNoticeCard(
                title: file.change.name, systemImage: file.change.systemImage,
                message: file.file.patch == nil
                    ? "GitHub shows no patch for this file (a binary file, or a diff too large for the API)."
                    : "No line changes.")
            {
                Button("Open on GitHub") { GitHubLinks.open(detail.pull.htmlURL + "/files") }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
        }
    }

    private func counts(_ file: GitHubPullRequestFile) -> some View {
        HStack(spacing: 6) {
            Text("+\(file.additions)")
                .foregroundStyle(Color(nsColor: Palette.diffAddedSign))
            Text("−\(file.deletions)")
                .foregroundStyle(Color(nsColor: Palette.diffRemovedSign))
        }
        .font(.settingsCaption.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.additions) added, \(file.deletions) removed")
    }
}

/// A file row: the status glyph, the name and folder, and GitHub's line counts. A click selects it at once (its rows
/// were built with the load).
private struct PRFileRow: View {
    let file: PRFile
    let selected: Bool
    let onSelect: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.change.systemImage)
                .font(.settingsCaption.weight(.bold))
                .foregroundStyle(file.change.tint)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.change.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.change.folder.isEmpty {
                    Text(file.change.folder)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            Text("+\(file.file.additions) −\(file.file.deletions)")
                .font(.settingsCaption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.horizontal, 8)
        .frame(minHeight: SidebarItemStyle.height)
        .background(Capsule().fill(selected ? Palette.selectedFill : hovered ? Palette.hoverFill : .clear))
        .overlay(Capsule().strokeBorder(selected ? Palette.selectedBorder : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture(perform: onSelect)
        .help(file.file.previousFilename.map { "\($0) → \(file.file.filename)" } ?? file.file.filename)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction { onSelect() }
    }

    private var accessibilityText: String {
        let counts = "\(file.file.additions) added, \(file.file.deletions) removed"
        return "\(file.file.filename), \(file.change.kindName), \(counts)"
    }
}

// MARK: Checks

private struct PRChecksTab: View {
    let checks: Loadable<[GitHubCheckRun]>

    var body: some View {
        switch checks {
        case .loaded(let runs):
            SectionCard("Checks", systemImage: PRTab.checks.systemImage, count: runs.count, contentPadding: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary(runs))
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(runs) { PRCheckRow(run: $0) }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        case .failed(let message):
            DiffNoticeCard(title: "Checks", systemImage: "exclamationmark.triangle", message: message)
        case .idle, .loading:
            DiffNoticeCard(title: "Checks", systemImage: "exclamationmark.triangle", message: "Not loaded.")
        }
    }

    private func summary(_ runs: [GitHubCheckRun]) -> String {
        guard let state = ChecksState(runs) else { return "No checks ran on the head commit." }
        return switch state {
        case .success: "All checks passed."
        case .failure: "Some checks failed."
        case .pending: "Some checks are still running."
        }
    }
}

/// A check run: its state glyph, name, conclusion and duration; a click opens it on GitHub.
private struct PRCheckRow: View {
    let run: GitHubCheckRun
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(run.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(detail)
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                GitHubLinks.open(run.htmlURL)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(RowIconButtonStyle())
            .help("Open this check on GitHub")
            .accessibilityLabel("Open \(run.name) on GitHub")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: SidebarItemStyle.height)
        .background(Capsule().fill(hovered ? Palette.hoverFill : .clear))
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
    }

    private var isFailure: Bool {
        ["failure", "timed_out", "cancelled", "action_required", "startup_failure"].contains(run.conclusion ?? "")
    }

    private var symbol: String {
        if run.status != "completed" { return "circle.dotted" }
        if isFailure { return "xmark.circle.fill" }
        return run.conclusion == "success" ? "checkmark.circle.fill" : "minus.circle"
    }

    private var tint: Color {
        if run.status != "completed" { return Color(nsColor: Palette.conflictB) }
        if isFailure { return Color(nsColor: Palette.diffRemovedSign) }
        return run.conclusion == "success" ? Color(nsColor: Palette.diffAddedSign) : .secondary
    }

    /// "success · 4m 0s", "in progress", "queued".
    private var detail: String {
        guard run.status == "completed" else { return run.status.replacingOccurrences(of: "_", with: " ") }
        let conclusion = (run.conclusion ?? "completed").replacingOccurrences(of: "_", with: " ")
        guard let start = run.startedAt, let end = run.completedAt, end >= start else { return conclusion }
        let seconds = Int(end.timeIntervalSince(start))
        let duration = seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
        return "\(conclusion) · \(duration)"
    }
}

// MARK: Skeleton

/// The loading detail: the Conversation card's lines and the side column's cards, in their loaded places.
private struct PRSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: SectionCardMetrics.spacing) {
            SectionCard("Conversation", systemImage: "text.bubble", countIsLoading: true) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        SkeletonLine(width: 20, height: 20)
                        SkeletonLine(width: 120, height: 11)
                    }
                    SkeletonLine(fraction: 0.9, height: 11)
                    SkeletonLine(fraction: 0.75, height: 11)
                    SkeletonLine(fraction: 0.55, height: 11)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            VStack(spacing: SectionCardMetrics.spacing) {
                ForEach(["Actions", "Reviewers", "Assignees"], id: \.self) { title in
                    SectionCard(title, countIsLoading: true) {
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonLine(fraction: 0.8, height: 11)
                            SkeletonLine(fraction: 0.5, height: 11)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 220)
        }
    }
}
