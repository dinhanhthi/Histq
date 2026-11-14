// The Create Pull Request form, an in-window `ModalCard` (never a sheet), opened from a branch's menu, a remote branch's
// menu or a branch badge dropped on another (`RepoMenus.openCreatePullRequest`). Head and base are branches of the
// tab's GitHub remote (GitHub opens a pull request only between branches it has); the head is the clicked branch, the
// base the dropped-on branch or the repository's default branch. The title starts as the head's name made readable,
// then becomes the commit's subject when the head has exactly one commit past the base (read with git from the
// remote-tracking branches, the commits GitHub compares), while the user has not typed one. The body has Write and a
// local Preview (inline markdown only, no request: `POST /markdown` would send the draft to GitHub on every switch).
// Reviewers, assignees and labels come from the API off the main actor; a list the token may not read (403, 404) only
// leaves its picker out. Create opens the pull request, then asks for the reviewers, labels and assignees; the new
// pull request's detail opens in panel2 even when one of those follow-ups fails (the failure shows above its tabs).
import AppKit
import HistqCore
import SwiftUI

/// What the form opens with: branch names on the GitHub remote; `base` nil takes the default branch.
struct PullRequestForm: Identifiable {
    let id = UUID()
    let head: String
    let base: String?
}

struct CreatePRView: View {
    let session: RepoSession
    let form: PullRequestForm
    let onClose: () -> Void

    private enum BodyTab: Hashable, CaseIterable {
        case write, preview

        var title: String {
            switch self {
            case .write: "Write"
            case .preview: "Preview"
            }
        }
    }

    /// What the title's prefill depends on: a new head or base proposes a new title.
    private struct TitleKey: Equatable {
        let head: String
        let base: String
    }

    /// The API's choices, read once when the form opens.
    private struct Choices: Sendable {
        var defaultBranch: String?
        var reviewers: Loadable<[String]>
        var assignees: Loadable<[String]>
        var labels: Loadable<[String]>
    }

    @FocusState private var titleFocused: Bool
    @State private var head = ""
    @State private var base = ""
    /// The user picked a base: the default branch, once read, no longer replaces it.
    @State private var baseTouched = false
    @State private var title = ""
    /// The title as the form last proposed it: replaced when the head or base changes, until the user types one.
    @State private var proposedTitle = ""
    @State private var bodyText = ""
    @State private var bodyTab = BodyTab.write
    @State private var draft = false
    @State private var reviewers: Set<String> = []
    @State private var assignees: Set<String> = []
    @State private var labels: Set<String> = []
    @State private var choices = Choices(reviewers: .loading, assignees: .loading, labels: .loading)
    @State private var error: String?
    @State private var creating = false
    @State private var fit = Fit()
    @Environment(\.modalAvailableHeight) private var availableHeight

    /// The laid-out heights the description editor's height comes from.
    private struct Fit: Equatable {
        var card: CGFloat = 0
        var scroll: CGFloat = 0
        var content: CGFloat = 0
        var editor: CGFloat = 0
    }

    /// The description's height: full, then down to the minimum when the window is too short for the whole form.
    private static let editorHeights: ClosedRange<CGFloat> = 48...96

    var body: some View {
        ModalCard(title: "Create a pull request", subtitle: subtitle, systemImage: "arrow.triangle.pull", width: 540) {
            // The sections scroll when the window is too short for them, so the buttons below always show: never
            // taller than their content (`FitHeight`), never taller than the card leaves them.
            FitHeight {
                ScrollView {
                    VStack(spacing: PanelContainerMetrics.padding) {
                        sections
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { fit.content = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { fit.scroll = $0 }
            ErrorText(message: error)
                .padding(.horizontal, SettingsMetrics.cardPadding)
        } actions: {
            Button("Cancel", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
            Button {
                submit()
            } label: {
                HStack(spacing: 6) {
                    if creating { ProgressView().controlSize(.mini) }
                    Text(draft ? "Create Draft" : "Create Pull Request")
                }
            }
            .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit || creating)
            .help(submitHelp)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { fit.card = $0 }
        .onChange(of: fit) {
            UITiming.content("create-pr fit available:\(Int(availableHeight ?? -1)) card:\(Int(fit.card)) "
                + "scroll:\(Int(fit.scroll)) content:\(Int(fit.content)) editor:\(Int(fit.editor))")
        }
        .onAppear {
            prefill()
            UITiming.content("create-pr \(form.head)")
            DispatchQueue.main.async { titleFocused = true }
            #if DEBUG
            debugSubmit()
            #endif
        }
        .task { await loadChoices() }
        .task(id: TitleKey(head: head, base: base)) { await proposeTitle() }
    }

    /// The description at full height while the card fits the window; shorter by what it lacks, down to the minimum
    /// (then the sections scroll). From the measured parts that do not depend on it (the card around the sections,
    /// the sections without the editor), so it settles in one more pass.
    private var editorHeight: CGFloat {
        let full = Self.editorHeights.upperBound
        guard let availableHeight, fit.card > 0, fit.content > 0, fit.editor > 0 else { return full }
        let chrome = fit.card - fit.scroll
        let others = fit.content - fit.editor
        return min(full, max(Self.editorHeights.lowerBound, (availableHeight - chrome - others).rounded(.down)))
    }

    @ViewBuilder private var sections: some View {
        ModalSection {
            HStack(alignment: .bottom, spacing: 8) {
                field("Base") {
                    branchPicker("Base", selection: Binding(get: { base }, set: { base = $0; baseTouched = true }))
                }
                Image(systemName: "arrow.left")
                    .foregroundStyle(.secondary)
                    .frame(height: 24)
                    .accessibilityHidden(true)
                field("Head (compare)") {
                    branchPicker("Head", selection: $head)
                }
                Spacer(minLength: 0)
            }
            field("Title") {
                TextField("Title", text: $title)
                    .textFieldStyle(.settings)
                    .focused($titleFocused)
                    .onSubmit(submit)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Description")
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    CapsuleTabs(selection: $bodyTab, tabs: BodyTab.allCases, title: { Text($0.title) }, compact: true)
                        .fixedSize()
                }
                Group {
                    switch bodyTab {
                    case .write:
                        TextEditor(text: $bodyText)
                            .font(.body)
                            .settingsTextEditor()
                            .overlay(alignment: .topLeading) {
                                if bodyText.isEmpty {
                                    Text("Describe the change (markdown)")
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 8)
                                        .allowsHitTesting(false)
                                }
                            }
                    case .preview:
                        BodyPreview(text: bodyText)
                    }
                }
                .frame(height: editorHeight)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { fit.editor = $0 }
            }
            HStack(spacing: 8) {
                Toggle("Draft", isOn: $draft)
                    .toggleStyle(CompactSwitch())
                Text("Create as a draft")
                    .foregroundStyle(.secondary)
            }
        }
        ModalSection(spacing: 10) {
            multiPicker("Reviewers", systemImage: "person.2", list: choices.reviewers, selection: $reviewers)
            multiPicker("Assignees", systemImage: "person.crop.circle", list: choices.assignees,
                        selection: $assignees)
            multiPicker("Labels", systemImage: "tag", list: choices.labels, selection: $labels)
        }
    }

    #if DEBUG
    /// DEBUG `-HistqCreatePRSubmit YES` (with `-HistqGitHubStub YES` only): picks a reviewer, an assignee and a label
    /// once the choices are in, then presses Create, so a launch runs the create, its follow-ups and the detail of the
    /// stub's PR #3.
    private func debugSubmit() {
        guard GitHubStub.isEnabled, AppState.launchFlag("-HistqCreatePRSubmit") == "YES" else { return }
        Task {
            for _ in 0..<50 where choices.labels.value == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(500))
            reviewers = Set(choices.reviewers.value?.prefix(1) ?? [])
            assignees = Set(choices.assignees.value?.prefix(1) ?? [])
            labels = Set(choices.labels.value?.prefix(1) ?? [])
            submit()
        }
    }
    #endif

    private var subtitle: String {
        guard let api = session.github.api else { return "GitHub is not connected for this tab." }
        return "On \(api.repository.fullName), from branches of \(api.remote)."
    }

    // MARK: Fields

    private func field<Field: View>(_ label: String, @ViewBuilder _ content: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// The branches of the GitHub remote, by their names there (`origin/HEAD` is not among the refs).
    private var branches: [String] {
        guard let remote = session.github.api?.remote else { return [] }
        return (session.refs.value?.remoteBranches ?? []).filter { $0.remote == remote }
            .map(RepoMenus.localName(of:)).sorted()
    }

    private func branchPicker(_ label: String, selection: Binding<String>) -> some View {
        CapsuleMenuPicker(label: label, selection: selection, title: Text(selection.wrappedValue)) {
            ForEach(branches, id: \.self) { Text($0).tag($0) }
        }
    }

    /// A row of choices the API gave: the picked ones, and a menu that checks and unchecks them. A list the token may
    /// not read leaves only its reason.
    private func multiPicker(
        _ title: String, systemImage: String, list: Loadable<[String]>, selection: Binding<Set<String>>
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            switch list {
            case .idle, .loading:
                SkeletonLine(width: 120, height: 11)
                    .accessibilityLabel("Loading")
            case .failed(let reason):
                Text(reason)
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(reason)
            case .loaded(let items) where items.isEmpty:
                Text("None on this repository")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
            case .loaded(let items):
                Text(selection.wrappedValue.isEmpty ? "None" : selection.wrappedValue.sorted().joined(separator: ", "))
                    .foregroundStyle(selection.wrappedValue.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(selection.wrappedValue.sorted().joined(separator: ", "))
                Spacer(minLength: 8)
                Menu {
                    ForEach(items, id: \.self) { item in
                        Toggle(item, isOn: Binding(
                            get: { selection.wrappedValue.contains(item) },
                            set: { on in
                                if on { selection.wrappedValue.insert(item) } else { selection.wrappedValue.remove(item) }
                            }))
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Edit")
                        MenuChevron()
                    }
                }
                .menuStyle(.button)
                .buttonStyle(BottomBarButtonStyle(height: 24, horizontalPadding: 12, menu: true))
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Edit \(title.lowercased())")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }

    // MARK: Prefill

    /// The menu's head, and its base or (until the default branch is read) `main`, `master`, or the first other branch.
    private func prefill() {
        head = form.head
        let others = branches.filter { $0 != form.head }
        base = form.base ?? (["main", "master"].first { others.contains($0) } ?? others.first ?? "")
        baseTouched = form.base != nil
    }

    /// The head's name made readable, then (when the head has exactly one commit past the base) that commit's subject,
    /// as long as the title is still the proposed one.
    private func proposeTitle() async {
        let humanized = Self.humanized(head)
        if title == proposedTitle {
            title = humanized
        }
        proposedTitle = humanized
        guard let remote = session.github.api?.remote, !head.isEmpty, !base.isEmpty, head != base else { return }
        let subjects = await session.commitSubjects(
            base: "refs/remotes/\(remote)/\(base)", head: "refs/remotes/\(remote)/\(head)", limit: 2)
        guard !Task.isCancelled, let subjects, subjects.count == 1, title == proposedTitle else { return }
        title = subjects[0]
        proposedTitle = subjects[0]
        UITiming.content("create-pr title from the commit")
    }

    /// `feature/add-login_page` → "Add login page": the last path part, dashes and underscores as spaces, the first
    /// letter capitalized.
    static func humanized(_ branch: String) -> String {
        let last = branch.split(separator: "/").last.map(String.init) ?? branch
        let words = last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: Loading

    /// The default branch, the collaborators (reviewers, without the token's own user), the assignable users and the
    /// labels, all at once.
    private func loadChoices() async {
        guard let api = session.github.api else {
            let reason = "GitHub is not connected."
            choices = Choices(reviewers: .failed(reason), assignees: .failed(reason), labels: .failed(reason))
            return
        }
        let loaded = await Self.fetchChoices(api.client, api.repository)
        guard !Task.isCancelled else { return }
        choices = loaded
        if !baseTouched, let branch = loaded.defaultBranch, branches.contains(branch), branch != head {
            base = branch
        }
        UITiming.content("create-pr choices " + [("reviewers", loaded.reviewers), ("assignees", loaded.assignees),
                                                 ("labels", loaded.labels)]
            .map { "\($0.0):" + ($0.1.value.map { "\($0.count)" } ?? "unavailable") }.joined(separator: " "))
    }

    @concurrent
    private nonisolated static func fetchChoices(_ client: GitHubClient, _ repository: HostedRepository) async
        -> Choices
    {
        async let info = try? client.repositoryInfo(repository)
        async let me = try? client.currentUser()
        async let collaborators = choice { try await client.collaborators(in: repository).map(\.login) }
        async let assignable = choice { try await client.assignableUsers(in: repository).map(\.login) }
        async let labels = choice { try await client.labels(in: repository).map(\.name) }
        let (user, reviewers) = await (me, collaborators)
        let others: Loadable<[String]> = switch reviewers {
        case .loaded(let logins): .loaded(logins.filter { $0 != user?.login })
        default: reviewers
        }
        return Choices(defaultBranch: await info?.defaultBranch, reviewers: others, assignees: await assignable,
                       labels: await labels)
    }

    /// A list, or why it is left out: a 403 or 404 means this token may not read it, which is not an error of the form.
    private nonisolated static func choice(_ body: () async throws -> [String]) async -> Loadable<[String]> {
        do {
            return .loaded(try await body())
        } catch GitHubError.forbidden, GitHubError.notFound {
            return .failed("Not available to this account.")
        } catch {
            return .failed(PullRequestDetailModel.message(for: error))
        }
    }

    // MARK: Create

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSubmit: Bool {
        session.github.api != nil && !head.isEmpty && !base.isEmpty && head != base && !trimmedTitle.isEmpty
    }

    private var submitHelp: String {
        if session.github.api == nil { return "GitHub is not connected for this tab." }
        if head == base { return "The head and the base are the same branch." }
        if trimmedTitle.isEmpty { return "A pull request needs a title." }
        return ""
    }

    /// Creates the pull request off the main actor, then its reviewers, labels and assignees; opens it once created.
    /// A refused create stays in the form (GitHub's reason, e.g. one already exists).
    private func submit() {
        guard canSubmit, !creating, let api = session.github.api else { return }
        error = nil
        creating = true
        let body = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = NewPullRequest(title: trimmedTitle, head: head, base: base, body: body.isEmpty ? nil : body,
                                     draft: draft)
        let extras = Extras(reviewers: reviewers.sorted(), assignees: assignees.sorted(), labels: labels.sorted())
        let session = session
        let formID = form.id
        Task {
            let result = await Self.create(request, extras: extras, api.client, api.repository)
            creating = false
            UITiming.content("create-pr " + ((try? result.get()).map {
                "created \($0.number) reviewers:\(extras.reviewers.count) assignees:\(extras.assignees.count) "
                    + "labels:\(extras.labels.count) follow-up-failures:\($0.problems.count)"
            } ?? "failed"))
            switch result {
            case .failure(let failure):
                error = "GitHub did not create it: \(PullRequestDetailModel.message(for: failure))"
            case .success(let created):
                if session.pullRequestForm?.id == formID { session.pullRequestForm = nil }
                session.github.refreshNow()
                session.selectHosted(.pullRequest(created.number))
                if !created.problems.isEmpty {
                    session.pullDetail.actionError = "Created #\(created.number), but "
                        + created.problems.joined(separator: "; ")
                }
            }
        }
    }

    private struct Extras: Sendable {
        let reviewers: [String]
        let assignees: [String]
        let labels: [String]
    }

    private struct Created: Sendable {
        let number: Int
        /// The follow-ups that failed, as "the reviewers were not requested: <reason>".
        let problems: [String]
    }

    @concurrent
    private nonisolated static func create(
        _ request: NewPullRequest, extras: Extras, _ client: GitHubClient, _ repository: HostedRepository
    ) async -> Result<Created, any Error> {
        let pull: GitHubPullRequest
        do {
            pull = try await client.createPullRequest(request, in: repository)
        } catch {
            return .failure(error)
        }
        var problems: [String] = []
        func followUp(_ what: String, _ body: () async throws -> Void) async {
            do { try await body() } catch {
                problems.append("\(what): \(PullRequestDetailModel.message(for: error))")
            }
        }
        if !extras.reviewers.isEmpty {
            await followUp("the reviewers were not requested") {
                try await client.requestReviewers(extras.reviewers, on: pull.number, in: repository)
            }
        }
        if !extras.labels.isEmpty {
            await followUp("the labels were not added") {
                try await client.addLabels(extras.labels, to: pull.number, in: repository)
            }
        }
        if !extras.assignees.isEmpty {
            await followUp("the assignees were not added") {
                try await client.addAssignees(extras.assignees, to: pull.number, in: repository)
            }
        }
        return .success(Created(number: pull.number, problems: problems))
    }
}

/// The body's Preview: the markdown's inline styles (bold, italic, code, links) with its line breaks, drawn locally.
/// Links open in the browser only when they are http or https.
private struct BodyPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            Group {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing to preview")
                        .foregroundStyle(.tertiary)
                } else {
                    Text(Self.rendered(text))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.inputSurface))
        .environment(\.openURL, OpenURLAction { url in
            GitHubLinks.open(url)
            return .handled
        })
    }

    private static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Its content's ideal height, at most the height proposed: around a `ScrollView`, which would otherwise take every
/// point offered, the card hugs its sections in a tall window and the sections scroll in a short one, from the first
/// frame (no measured height needed).
private struct FitHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, proposal.height ?? ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
