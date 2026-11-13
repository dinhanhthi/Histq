// A repo tab's sidebar (panel 1): tabs Branches (Local and Remote cards, ahead/behind counts), Tags, and Pull
// requests & Issues (a hint until GitHub is connected, Phase 11). Each section is its own collapsible card. A click selects a row at once; the branch actions
// (checkout, menus) come in Phase 5.
import HistqCore
import SwiftUI

/// A sidebar tab. The raw value is its `-HistqSelect sidebar:<value>` name and its timing detail.
enum SidebarTab: String, CaseIterable, Hashable, Sendable {
    case branches, tags, prs

    /// `-HistqSelect sidebar:<value>`: the raw value, or `pullRequests` / `pr` for `prs`.
    init?(selectValue: String) {
        switch selectValue.lowercased() {
        case "pullrequests", "pull-requests", "pr", "issues": self = .prs
        default: self.init(rawValue: selectValue.lowercased())
        }
    }

    var title: String {
        switch self {
        case .branches: "Branches"
        case .tags: "Tags"
        case .prs: "Pull requests & Issues"
        }
    }

    /// The picker's label, beside the icon.
    var shortTitle: String {
        switch self {
        case .branches: "Branches"
        case .tags: "Tags"
        case .prs: "PRs"
        }
    }

    var systemImage: String {
        switch self {
        case .branches: "arrow.triangle.branch"
        case .tags: "tag"
        case .prs: "arrow.triangle.pull"
        }
    }
}

/// A selectable sidebar row, by its short name (`main`, `origin/main`, `v1.0`).
enum SidebarItem: Hashable, Sendable {
    case local(String)
    case remote(String)
    case tag(String)

    /// The `select` line of the timing log: `branch main`, `branch origin/main`, `tag v1.0`.
    var timingDetail: String {
        switch self {
        case .local(let name), .remote(let name): "branch \(name)"
        case .tag(let name): "tag \(name)"
        }
    }
}

/// Sizes of the sidebar.
private enum SidebarMetrics {
    /// Between two section cards, and above the first one.
    static let cardSpacing = SectionCardMetrics.spacing
    /// Inside a section card, around its rows.
    static let cardPadding: CGFloat = 6
    /// Between two rows' capsules: tighter than Settings', the lists are long.
    static let rowSpacing: CGFloat = 2
}

/// The sidebar of a repo tab: the tab picker across its width (icon and short name; the full name is the tooltip),
/// then its sections as cards on the window glass, in a scroll view. The cards wait for the refs (capsule skeleton
/// rows in the same cards until then); the tab capsules and the cards' chevrons work at once.
struct SidebarView: View {
    @Bindable var session: RepoSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CapsuleTabs(
                selection: Binding(get: { session.sidebarTab }, set: { session.selectSidebarTab($0) }),
                tabs: SidebarTab.allCases,
                title: { Text($0.shortTitle) },
                compact: true,
                help: \.title,
                fillsWidth: true,
                systemImage: \.systemImage)
            ScrollView {
                VStack(alignment: .leading, spacing: SidebarMetrics.cardSpacing) {
                    sections
                }
                .padding(.vertical, SidebarMetrics.cardSpacing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var sections: some View {
        switch (session.sidebarTab, session.refs) {
        case (.prs, _):
            PullRequestsHint()
        case (.branches, .loaded(let refs)):
            BranchSections(session: session, refs: refs)
                .onAppear { UITiming.content("sidebar \(session.url.lastPathComponent)") }
        case (.tags, .loaded(let refs)):
            SidebarSection(title: "Tags", count: refs.tags.count, isExpanded: $session.tagsExpanded) {
                TagRows(session: session, tags: refs.tags)
            }
            .onAppear { UITiming.content("sidebar \(session.url.lastPathComponent)") }
        case (.branches, .idle), (.branches, .loading):
            SidebarSection(title: "Local", count: nil, isExpanded: $session.localExpanded) {
                SkeletonRows(fractions: [0.45, 0.6, 0.35, 0.7, 0.5])
            }
            SidebarSection(title: "Remote", count: nil, isExpanded: $session.remoteExpanded) {
                SkeletonRows(fractions: [0.3, 0.55, 0.4])
            }
        case (.tags, .idle), (.tags, .loading):
            SidebarSection(title: "Tags", count: nil, isExpanded: $session.tagsExpanded) {
                SkeletonRows(fractions: [0.3, 0.45, 0.35, 0.5])
            }
        case (_, .failed(let message)):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(SidebarMetrics.cardPadding + 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
        }
    }
}

/// The Local and Remote cards. Remote branches are grouped by remote inside their card.
private struct BranchSections: View {
    @Bindable var session: RepoSession
    let refs: Refs

    var body: some View {
        SidebarSection(title: "Local", count: refs.localBranches.count, isExpanded: $session.localExpanded) {
            if refs.localBranches.isEmpty { EmptyRow(text: "No local branches") }
            ForEach(refs.localBranches, id: \.refName) { branch in
                BranchRow(session: session, item: .local(branch.name), name: branch.name,
                          systemImage: branch.isHead ? "checkmark" : "laptopcomputer") {
                    AheadBehind(branch: branch)
                }
            }
        }
        SidebarSection(title: "Remote", count: refs.remoteBranches.count, isExpanded: $session.remoteExpanded) {
            if refs.remoteBranches.isEmpty { EmptyRow(text: "No remote branches") }
            ForEach(remotes, id: \.name) { remote in
                Text(remote.name)
                    .font(.settingsCaption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                ForEach(remote.branches, id: \.refName) { branch in
                    BranchRow(session: session, item: .remote(branch.name),
                              name: String(branch.name.dropFirst(remote.name.count + 1)),
                              systemImage: "cloud") { EmptyView() }
                }
            }
        }
    }

    /// Remote branches by remote, in the order git listed them.
    private var remotes: [(name: String, branches: [RemoteBranch])] {
        var order: [String] = []
        var groups: [String: [RemoteBranch]] = [:]
        for branch in refs.remoteBranches {
            if groups[branch.remote] == nil { order.append(branch.remote) }
            groups[branch.remote, default: []].append(branch)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

private struct TagRows: View {
    let session: RepoSession
    let tags: [TagRef]

    var body: some View {
        if tags.isEmpty { EmptyRow(text: "No tags") }
        ForEach(tags, id: \.refName) { tag in
            BranchRow(session: session, item: .tag(tag.name), name: tag.name,
                      systemImage: tag.isAnnotated ? "tag.fill" : "tag") { EmptyView() }
        }
    }
}

/// A section of the sidebar in its own collapsible `SectionCard`: its rows, tightly stacked. `count` nil while the
/// refs load.
private struct SidebarSection<Content: View>: View {
    let title: String
    let count: Int?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        SectionCard(title, count: count, countIsLoading: count == nil, isExpanded: $isExpanded,
                    contentPadding: SidebarMetrics.cardPadding) {
            VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                content()
            }
        }
    }
}

/// The text of an empty section.
private struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: SidebarItemStyle.height)
    }
}

/// A selectable row: icon, name (truncated in the middle), then `trailing` (the ahead/behind counts). Selecting it
/// happens on the click, before anything loads.
private struct BranchRow<Trailing: View>: View {
    let session: RepoSession
    let item: SidebarItem
    let name: String
    let systemImage: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        Button {
            session.selectSidebarItem(item)
        } label: {
            Label {
                HStack(spacing: 4) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    trailing()
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .buttonStyle(SidebarItemStyle(selected: session.sidebarSelection == item))
        .help(name)
        .accessibilityAddTraits(session.sidebarSelection == item ? .isSelected : [])
    }
}

/// `↑2 ↓1` against the upstream; "gone" when the upstream was deleted. Nothing when in sync or without upstream.
private struct AheadBehind: View {
    let branch: LocalBranch

    var body: some View {
        HStack(spacing: 4) {
            if branch.upstreamGone {
                Text("gone")
            } else {
                if branch.ahead > 0 { Text("\(Image(systemName: "arrow.up"))\(branch.ahead)") }
                if branch.behind > 0 { Text("\(Image(systemName: "arrow.down"))\(branch.behind)") }
            }
        }
        .font(.settingsCaption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if branch.upstreamGone { return "upstream gone" }
        return [branch.ahead > 0 ? "\(branch.ahead) ahead" : nil, branch.behind > 0 ? "\(branch.behind) behind" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// Until Phase 11 connects GitHub: where to do it, in a card.
private struct PullRequestsHint: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        SectionCard("GitHub", systemImage: "person.crop.circle.badge.plus") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect GitHub in Settings")
                    .font(.body.weight(.medium))
                Text("Pull requests and issues of this repository show here once a GitHub account is connected.")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { model.toggleSettings() }
                    .buttonStyle(RowTextButtonStyle())
            }
        }
    }
}

/// A section card's rows while the refs load: icon circles and name capsules of the given widths (a fraction of the
/// row).
private struct SkeletonRows: View {
    let fractions: [CGFloat]

    var body: some View {
        ForEach(fractions.indices, id: \.self) { index in
            HStack(spacing: 8) {
                SkeletonLine(width: 14, height: 14)
                    .frame(width: 20)
                SkeletonLine(fraction: fractions[index], height: 11)
            }
            .padding(.horizontal, 10)
            .frame(height: SidebarItemStyle.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
