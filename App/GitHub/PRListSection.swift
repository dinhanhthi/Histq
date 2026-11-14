// The sidebar's PRs tab: the repo's GitHub lists in their own cards (My PRs, Review requested, All open, Issues
// assigned to me), or the Connect GitHub card without a connected account. A row shows the number, title, author
// avatar, a draft capsule and the checks state; a click selects it at once and panel2 shows its placeholder in the same
// frame. Also `GitHubDriver`, which keeps the tab's `GitHubStore` running while the repo tab shows (the graph's PR
// badges need its lists too).
import AppKit
import HistqCore
import SwiftUI

/// Drives the tab's `GitHubStore` while the repo tab shows: `watch` resolves the connection, reads the lists once (the
/// graph's PR badges), and keeps them fresh while the PRs tab shows; it restarts when the profile, the remotes, the
/// window's visibility or the sidebar tab change, stops when the repo tab or the window goes away, and pauses while the
/// window is hidden or covered. Draws nothing.
struct GitHubDriver: View {
    let session: RepoSession
    @Environment(WindowModel.self) private var model
    @Environment(WindowState.self) private var windowState

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .task(id: source) { [session, source] in
                await session.github.watch(source, profile: session.profile)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if windowState.isVisible, session.sidebarTab == .prs { session.github.refreshIfStale() }
            }
    }

    private var source: GitHubStore.Source {
        let profile = session.profile
        #if DEBUG
        let isStub = GitHubStub.isEnabled
        #else
        let isStub = false
        #endif
        // A store that failed to load reads as no profile: the Connect card, whose Settings page shows the failure.
        let profilesLoaded = switch ProfileLibrary.shared.state {
        case .loaded, .failed: true
        case .idle, .loading: false
        }
        return GitHubStore.Source(
            profilesLoaded: profilesLoaded, profileID: profile?.id, account: profile?.github,
            remotes: session.remotes, remotesKnown: session.refs.value != nil, settingsOpen: model.isSettingsOpen,
            windowVisible: windowState.isVisible, listsShown: session.sidebarTab == .prs, isStub: isStub)
    }
}

/// The PRs tab's cards; `GitHubDriver` keeps their lists fresh while they show.
struct PullRequestSections: View {
    let session: RepoSession

    var body: some View {
        let store = session.github
        VStack(alignment: .leading, spacing: SidebarMetrics.cardSpacing) {
            if let notice = store.actionNotice {
                PRActionErrorCard(message: notice) { store.actionNotice = nil }
                    .onAppear { UITiming.content("prs notice \(notice)") }
            }
            switch store.connection {
            case .resolving:
                ForEach(GitHubStore.List.allCases, id: \.self) { list in
                    ListCard(session: session, list: list, realAvatars: false)
                }
            case .notConnected(let account):
                ConnectGitHubCard(account: account)
            case .noRemote(let host):
                SectionCard("GitHub", systemImage: "exclamationmark.triangle") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No GitHub remote")
                            .font(.body.weight(.medium))
                        Text("None of this repository's remotes is on \(host), the host of this tab's GitHub account.")
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .connected(let repository):
                ForEach(GitHubStore.List.allCases, id: \.self) { list in
                    ListCard(session: session, list: list,
                             realAvatars: repository.host == "github.com" && !isStub)
                }
            }
        }
    }

    private var isStub: Bool {
        #if DEBUG
        GitHubStub.isEnabled
        #else
        false
        #endif
    }
}

/// One list in its own collapsible card: skeleton rows until its first read, the read's error above the rows it
/// kept, then the rows.
private struct ListCard: View {
    let session: RepoSession
    let list: GitHubStore.List
    /// The authors' GitHub avatars may load (github.com, not the stub); `AvatarStore`'s mode still decides.
    let realAvatars: Bool

    var body: some View {
        let store = session.github
        let state = store.lists[list]
        SectionCard(list.title, systemImage: list.systemImage, count: state?.rows?.count,
                    countIsLoading: state?.rows == nil && state?.error == nil,
                    isExpanded: Binding(get: { !store.collapsed.contains(list) },
                                        set: { if $0 { store.collapsed.remove(list) } else { store.collapsed.insert(list) } }),
                    contentPadding: SidebarMetrics.cardPadding) {
            VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                if let error = state?.error {
                    ListErrorRow(error: error)
                }
                if let rows = state?.rows {
                    if rows.isEmpty, state?.error == nil { EmptyRow(text: list.emptyText) }
                    ForEach(rows) { row in
                        HostedRowView(session: session, row: row, checks: row.headSHA.flatMap { store.checks[$0] },
                                      realAvatars: realAvatars)
                    }
                } else if state?.error == nil {
                    SkeletonRows(fractions: list == .allOpen ? [0.7, 0.5, 0.6] : [0.6, 0.45])
                }
            }
        }
    }
}

/// A failed read: GitHub's reason, and for a refused token the way to reconnect.
private struct ListErrorRow: View {
    let error: GitHubStore.ListError
    @Environment(WindowModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error.message, systemImage: "exclamationmark.triangle")
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if error.reconnect {
                Text("Reconnect in Settings › Integrations.")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reconnect…") { model.selectSettings(.integrations) }
                    .buttonStyle(RowTextButtonStyle())
            }
        }
        .padding(.leading, SidebarMetrics.rowLeading)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Without a connected account: what is missing, and the button to Settings › Integrations.
private struct ConnectGitHubCard: View {
    /// Set when the profile has an account whose token is not in the Keychain.
    let account: Profile.GitHubAccount?
    @Environment(WindowModel.self) private var model

    var body: some View {
        SectionCard("GitHub", systemImage: "person.crop.circle.badge.plus") {
            VStack(alignment: .leading, spacing: 8) {
                Text(account == nil ? "Connect GitHub" : "Reconnect GitHub")
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(account == nil ? "Connect GitHub…" : "Reconnect…") { model.selectSettings(.integrations) }
                    .buttonStyle(RowTextButtonStyle(prominent: true))
                    .help("Settings › Integrations")
            }
        }
    }

    private var detail: String {
        guard let account else {
            return "Pull requests and issues of this repository show here once this tab's profile has a GitHub account."
        }
        return "The token of \(account.login) on \(account.host) is not in the Keychain."
    }
}

/// A pull request's or an issue's row: the author's avatar, the number, the title, then a draft capsule and the
/// checks state. A click selects it and panel2 shows it at once; there is no double-click action.
private struct HostedRowView: View {
    let session: RepoSession
    let row: HostedRow
    let checks: ChecksState?
    let realAvatars: Bool
    @State private var hovered = false
    /// Bumped when `AvatarStore` has a new image for this author (or the avatar mode changed).
    @State private var avatarRevision = 0
    @Environment(\.displayScale) private var displayScale

    private static let avatarSize: CGFloat = 16

    var body: some View {
        let selected = session.openHosted == row.item
        HStack(spacing: SidebarMetrics.iconGap) {
            avatar
                .id(avatarRevision)
                .frame(width: SidebarMetrics.iconSlot, alignment: .leading)
            HStack(spacing: 4) {
                Text("#\(row.number)")
                    .font(.settingsCaption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if row.isDraft {
                    Text("Draft")
                        .font(.settingsCaption)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(Palette.tabFill))
                }
                if let checks { ChecksIcon(state: checks) }
            }
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        // `BranchRow`'s look: a neutral capsule when selected, a hover capsule otherwise.
        .padding(.leading, SidebarMetrics.rowLeading)
        .padding(.trailing, 10)
        .frame(minHeight: SidebarItemStyle.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(selected ? Palette.selectedFill : hovered ? Palette.hoverFill : .clear))
        .overlay(Capsule().strokeBorder(selected ? Palette.selectedBorder : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture { session.selectHosted(row.item) }
        .onReceive(NotificationCenter.default.publisher(for: AvatarStore.didChange)) { note in
            guard let changed = note.userInfo?[AvatarStore.emailKey] as? String else { return avatarRevision &+= 1 }
            if AvatarStore.matches(email: email, name: login, changed: changed) { avatarRevision &+= 1 }
        }
        .help(row.authorLogin.map { "\(row.title)\n#\(row.number) by \($0)" } ?? "\(row.title)\n#\(row.number)")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction { session.selectHosted(row.item) }
    }

    private var login: String { row.authorLogin ?? "?" }

    /// GitHub's noreply address of the author: `AvatarStore` loads its GitHub avatar in real mode. Empty (a drawn
    /// avatar from the login, never a request) for the stub and for Enterprise hosts, whose avatars are elsewhere.
    private var email: String {
        guard realAvatars, let id = row.authorID, let login = row.authorLogin else { return "" }
        return "\(id)+\(login)@users.noreply.github.com"
    }

    @ViewBuilder private var avatar: some View {
        let pixels = Int((Self.avatarSize * displayScale).rounded())
        if let image = AvatarStore.shared.avatar(email: email, name: login, pixels: pixels) {
            Image(nsImage: image)
                .resizable()
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            SkeletonLine(width: Self.avatarSize, height: Self.avatarSize)
        }
    }

    private var accessibilityText: String {
        let kind = if case .issue = row.item { "Issue" } else { "Pull request" }
        var parts = ["\(kind) \(row.number)", row.title]
        if let author = row.authorLogin { parts.append("by \(author)") }
        if row.isDraft { parts.append("draft") }
        if let checks { parts.append(ChecksIcon.text(checks)) }
        return parts.joined(separator: ", ")
    }
}

/// The checks state as a small icon: green check, red cross, or a yellow dotted circle while runs are unfinished.
private struct ChecksIcon: View {
    let state: ChecksState

    var body: some View {
        Image(systemName: symbol)
            .font(.settingsCaption)
            // The diff's added/removed signs and the conflict editor's B color: the palette's green, red and yellow.
            .foregroundStyle(Color(nsColor: color))
            .help(Self.text(state))
    }

    private var symbol: String {
        switch state {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "circle.dotted"
        }
    }

    private var color: NSColor {
        switch state {
        case .success: Palette.diffAddedSign
        case .failure: Palette.diffRemovedSign
        case .pending: Palette.conflictB
        }
    }

    static func text(_ state: ChecksState) -> String {
        switch state {
        case .success: "checks passed"
        case .failure: "checks failed"
        case .pending: "checks running"
        }
    }
}
