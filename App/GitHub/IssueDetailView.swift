// An issue in panel2, laid out like the pull request detail, each part in its own card: the header (back, title,
// number, state pill, "author opened this issue on <date> · N comments"), the Conversation (the body and the comments
// in one `GitHubHTMLView`, the same page as a pull request's), the comment box, and a side column with Close/Reopen
// (confirmed), the assignees and the labels. The row click shows the header and skeleton cards in the same frame
// (`PlaceholderCard`); the issue and its comments load off the main actor in one go (`IssueDetailModel`). The
// actions call GitHub through the tab's `GitHubStore` client.
import AppKit
import HistqCore
import SwiftUI

// MARK: - Model

/// Everything the detail shows, read in one load.
struct IssueDetail: Sendable {
    let issue: GitHubIssue
    let commentCount: Int
    /// The body, then the comments by date.
    let timelineHTML: String

    var isOpen: Bool { issue.state == "open" }
}

/// A GitHub action of the issue detail.
enum IssueAction: Equatable, Sendable {
    case comment(String)
    case setOpen(Bool)

    var progressTitle: String {
        switch self {
        case .comment: "Commenting…"
        case .setOpen(let open): open ? "Reopening…" : "Closing…"
        }
    }

    var failureTitle: String {
        switch self {
        case .comment: "The comment was not posted"
        case .setOpen(let open): open ? "Reopen failed" : "Close failed"
        }
    }

    /// The failure's title when another issue shows by the time it returns: it names `number`.
    func failureTitle(of number: Int) -> String {
        switch self {
        case .comment: "The comment on #\(number) was not posted"
        case .setOpen(let open): open ? "Reopen of #\(number) failed" : "Close of #\(number) failed"
        }
    }

    /// The timing log's word (`content issue 2 action comment ok`).
    var timingName: String {
        switch self {
        case .comment: "comment"
        case .setOpen(let open): open ? "reopen" : "close"
        }
    }
}

/// The open issue of a repo tab: its load, the comment box and the running action. `RepoSession.selectHosted` starts a
/// load in the click's call (`state` is `.loading` when it returns); a newer select or `close` drops an older load's
/// answer.
@Observable
@MainActor
final class IssueDetailModel {
    private(set) var number: Int?
    private(set) var state: Loadable<IssueDetail> = .idle
    var draft = ""
    /// The actions running on GitHub, by issue: one at a time for each. An action belongs to the issue it started on,
    /// not to the detail, which may show another one by the time it returns.
    private(set) var busy: [Int: IssueAction] = [:]
    /// The last action's failure (or a failed reload after it), above the cards until dismissed or the next action.
    var actionError: String?

    /// The shown issue's running action.
    var running: IssueAction? { number.flatMap { busy[$0] } }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    #if DEBUG
    /// DEBUG `-HistqIssueAction comment|close|reopen`: runs that action once, on the first load, without its
    /// confirmation, so a launch exercises the action path and its reload. Only with `-HistqGitHubStub YES`: never an
    /// unconfirmed action on a real account.
    private static var launchAction: IssueAction? = switch GitHubStub.isEnabled
        ? AppState.launchFlag("-HistqIssueAction") : nil {
    case "comment": .comment("QA comment")
    case "close": .setOpen(false)
    case "reopen": .setOpen(true)
    default: nil
    }
    #endif

    /// Loads issue `number`; `quiet` keeps the shown detail until the new one is in (after an action).
    func load(_ number: Int, github: GitHubStore, quiet: Bool = false) {
        task?.cancel()
        generation &+= 1
        if number != self.number {
            // Another issue: its own box. The same one opened again keeps its draft.
            draft = ""
            actionError = nil
        }
        self.number = number
        if !quiet || state.value == nil { state = .loading }
        guard let api = github.api else {
            state = .failed("GitHub is not connected for this tab: connect it in Settings › Integrations.")
            return
        }
        let generation = generation
        task = Task { [weak self] in
            let result = await Self.fetch(api.client, api.repository, number: number)
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            switch result {
            case .success(let detail):
                state = .loaded(detail)
                #if DEBUG
                if let action = Self.launchAction {
                    Self.launchAction = nil
                    perform(action, on: number, github: github)
                }
                #endif
            case .failure(let error):
                if quiet, state.value != nil {
                    actionError = "Could not reload the issue: \(PullRequestDetailModel.message(for: error))"
                } else {
                    state = .failed(PullRequestDetailModel.message(for: error))
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

    /// Runs `action` on issue `number` (the one whose detail the user acted on), then reloads it and the PRs tab's
    /// lists. A failure shows above the cards while that issue shows; otherwise it names the number in the PRs tab
    /// (`GitHubStore.actionNotice`).
    func perform(_ action: IssueAction, on number: Int, github: GitHubStore) {
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
            UITiming.content("issue \(number) action \(action.timingName) \(error == nil ? "ok" : "failed")")
            let showing = isShowing(number)
            if let error {
                let message = PullRequestDetailModel.message(for: error)
                if showing {
                    actionError = "\(action.failureTitle): \(message)"
                } else {
                    github.actionNotice = "\(action.failureTitle(of: number)): \(message)"
                }
                return
            }
            if case .comment = action, self.number == number { draft = "" }
            github.refreshNow()
            if showing { load(number, github: github, quiet: true) }
        }
    }

    /// Whether the detail shows issue `number` (loading or loaded), not another one or nothing (closed).
    private func isShowing(_ number: Int) -> Bool {
        guard self.number == number else { return false }
        if case .idle = state { return false }
        return true
    }

    @concurrent
    private nonisolated static func fetch(_ client: GitHubClient, _ repository: HostedRepository, number: Int) async
        -> Result<IssueDetail, any Error>
    {
        async let issue = client.issue(number, in: repository)
        async let comments = client.comments(on: number, in: repository)
        do {
            let (issue, comments) = try await (issue, comments)
            return .success(IssueDetail(issue: issue, commentCount: comments.count,
                                        timelineHTML: timeline(issue, comments)))
        } catch {
            return .failure(error)
        }
    }

    /// The body, then the comments, oldest first, in the pull request timeline's boxes.
    private nonisolated static func timeline(_ issue: GitHubIssue, _ comments: [GitHubComment]) -> String {
        let body = PRTimeline.item(
            author: issue.user?.login, action: "opened this issue", badge: nil, date: issue.createdAt,
            bodyHTML: PRTimeline.bodyHTML(issue.bodyHTML, issue.body), emptyText: "No description provided.")
        let sorted = comments.enumerated().sorted { a, b in
            switch (a.element.createdAt, b.element.createdAt) {
            case let (x?, y?) where x != y: x < y
            default: a.offset < b.offset
            }
        }.map(\.element)
        return ([body] + sorted.map { comment in
            PRTimeline.item(author: comment.user?.login, action: "commented", badge: nil, date: comment.createdAt,
                            bodyHTML: PRTimeline.bodyHTML(comment.bodyHTML, comment.body), emptyText: nil)
        }).joined()
    }

    @concurrent
    private nonisolated static func run(
        _ action: IssueAction, _ client: GitHubClient, _ repository: HostedRepository, number: Int
    ) async -> (any Error)? {
        do {
            switch action {
            case .comment(let body): _ = try await client.comment(on: number, in: repository, body: body)
            case .setOpen(let open): try await client.setOpen(open, number: number, in: repository)
            }
            return nil
        } catch {
            return error
        }
    }
}

// MARK: - Views

/// Panel2 while an issue is open: the header card at once, then the conversation's cards (skeletons until loaded).
struct IssueDetailView: View {
    let session: RepoSession
    let number: Int
    @Environment(WindowModel.self) private var model

    var body: some View {
        let detail = session.issueDetail
        VStack(spacing: SectionCardMetrics.spacing) {
            IssueHeaderCard(session: session, number: number)
            if let error = detail.actionError {
                PRActionErrorCard(message: error) { detail.actionError = nil }
            }
            Group {
                switch detail.state {
                case .idle, .loading:
                    PlaceholderCard(
                        token: session.hostedToken, detail: "issue \(number)",
                        isCurrent: { [model, session, number] in
                            model.selectedSession === session && session.openHosted == .issue(number)
                        }
                    ) {
                        IssueSkeleton()
                    }
                case .loaded(let value):
                    IssueContent(session: session, detail: value)
                        .onAppear { UITiming.content("issue \(number) conversation \(value.commentCount)") }
                case .failed(let message):
                    DiffNoticeCard(title: "Issue", systemImage: "exclamationmark.triangle", message: message)
                        .onAppear { UITiming.content("issue \(number) failed") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Back, the title and number, the state pill and Open on GitHub; the "opened" line. The title comes from the PRs
/// tab's row until the issue is in.
private struct IssueHeaderCard: View {
    let session: RepoSession
    let number: Int

    var body: some View {
        let value = session.issueDetail.state.value
        let title = value?.issue.title ?? session.github.row(for: .issue(number))?.title
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
                    Image(systemName: "smallcircle.filled.circle")
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
                        IssueStatePill(isOpen: value.isOpen)
                        Button {
                            GitHubLinks.open(value.issue.htmlURL)
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
                            .truncationMode(.tail)
                    } else {
                        SkeletonLine(width: 260, height: 11)
                    }
                }
                .padding(.leading, 8)
                .padding(.bottom, 2)
            }
        }
    }

    /// "reviewer opened this issue on Nov 11, 2026 · 1 comment".
    private func summary(_ value: IssueDetail) -> Text {
        let issue = value.issue
        let date = issue.createdAt.map { " on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        let count = value.commentCount
        return Text(issue.user?.login ?? "ghost").fontWeight(.semibold)
            + Text(" opened this issue\(date) · \(count) \(count == 1 ? "comment" : "comments")")
    }
}

/// Open (green) or Closed (GitHub's done purple is not a `Palette` color: the brand blue), as on GitHub.
private struct IssueStatePill: View {
    let isOpen: Bool

    var body: some View {
        let (title, symbol, fill, text): (String, String, Color, Color) = isOpen
            ? ("Open", "smallcircle.filled.circle", Color(nsColor: Palette.diffAddedFill), Color(nsColor: Palette.diffAddedSign))
            : ("Closed", "checkmark.circle", Palette.primaryFill, Palette.onAccent)
        Label(title, systemImage: symbol)
            .font(.settingsCaption.weight(.semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(fill))
            .accessibilityLabel("State: \(title)")
    }
}

/// The conversation and the comment box, with the side column on the right (below them when panel2 is narrow).
private struct IssueContent: View {
    let session: RepoSession
    let detail: IssueDetail

    private static let sideWidth: CGFloat = 220
    /// Narrower than this, the side column goes under the conversation.
    private static let wideEnough: CGFloat = 560

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.wideEnough {
                HStack(alignment: .top, spacing: SectionCardMetrics.spacing) {
                    main
                    ScrollView {
                        IssueSideColumn(session: session, detail: detail)
                    }
                    .scrollIndicators(.never)
                    .frame(width: Self.sideWidth)
                }
            } else {
                VStack(spacing: SectionCardMetrics.spacing) {
                    main
                    ScrollView {
                        IssueSideColumn(session: session, detail: detail)
                    }
                    .frame(maxHeight: min(240, proxy.size.height / 2))
                }
            }
        }
    }

    private var main: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            SectionCard("Conversation", systemImage: "text.bubble", count: detail.commentCount) {
                GitHubHTMLView(html: detail.timelineHTML) { [number = detail.issue.number] in
                    UITiming.content("issue \(number) conversation html")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            IssueCommentCard(session: session)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The comment box.
private struct IssueCommentCard: View {
    let session: RepoSession

    var body: some View {
        @Bindable var model = session.issueDetail
        SectionCard("Comment", systemImage: "square.and.pencil") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $model.draft)
                    .font(.body)
                    .settingsTextEditor()
                    .frame(height: 64)
                    .overlay(alignment: .topLeading) {
                        if model.draft.isEmpty {
                            Text("Leave a comment")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    Button {
                        submit(model)
                    } label: {
                        HStack(spacing: 6) {
                            if case .comment? = model.running { ProgressView().controlSize(.mini) }
                            Text("Comment")
                        }
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .disabled(model.running != nil || trimmed(model).isEmpty)
                }
            }
        }
    }

    private func trimmed(_ model: IssueDetailModel) -> String {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit(_ model: IssueDetailModel) {
        let body = trimmed(model)
        guard model.running == nil, !body.isEmpty, let number = model.number else { return }
        model.perform(.comment(body), on: number, github: session.github)
    }
}

/// The right column: the actions, then assignees and labels, each in its own card.
private struct IssueSideColumn: View {
    let session: RepoSession
    let detail: IssueDetail
    @Environment(WindowModel.self) private var model

    var body: some View {
        let busy = session.issueDetail.busy[detail.issue.number]
        VStack(spacing: SectionCardMetrics.spacing) {
            SectionCard("Actions", systemImage: "bolt") {
                VStack(alignment: .leading, spacing: 10) {
                    Button(detail.isOpen ? "Close Issue…" : "Reopen Issue…") { confirmSetOpen(!detail.isOpen) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(busy != nil)
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
            SectionCard("Assignees", systemImage: "person.crop.circle", count: detail.issue.assignees?.count ?? 0) {
                let assignees = detail.issue.assignees ?? []
                if assignees.isEmpty {
                    PRSideEmpty(text: "No one assigned")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(assignees, id: \.id) { PRPersonRow(login: $0.login, state: nil, showsState: false) }
                    }
                }
            }
            SectionCard("Labels", systemImage: "tag", count: detail.issue.labels?.count ?? 0) {
                let labels = detail.issue.labels ?? []
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

    private func confirmSetOpen(_ open: Bool) {
        let number = detail.issue.number
        model.presentModal(.confirmation(ModalConfirmation(
            title: open ? "Reopen #\(number)?" : "Close #\(number)?",
            message: open ? "The issue opens again on GitHub." : "The issue closes on GitHub; it can be reopened later.",
            button: open ? "Reopen" : "Close Issue", isDestructive: !open,
            perform: { [session] in session.issueDetail.perform(.setOpen(open), on: number, github: session.github) })))
    }
}

/// The loading detail: the Conversation card's lines and the side column's cards, in their loaded places.
private struct IssueSkeleton: View {
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
                ForEach(["Actions", "Assignees", "Labels"], id: \.self) { title in
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
