// A repo tab's sidebar (panel 1): tabs Branches (Local and Remote cards, ahead/behind counts), Tags, and Pull
// requests & Issues (a hint until GitHub is connected, Phase 11). Each section is its own collapsible card. A click
// selects a row at once and the graph jumps to its commit; a double-click checks it out (the single click never waits
// for it); a right-click opens the same menu as its badge in the graph. The Remote card's header menu adds a remote and
// renames, removes, re-points or mirrors one.
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
    /// A row's icon from its capsule's leading edge. The card header's icon starts after its padding (10), the chevron
    /// (12) and a gap (6), 28 pt into the card; a row starts at the card padding (6) plus this, so the rows' icons
    /// line up with the section's own icon.
    static let rowLeading: CGFloat = 28 - cardPadding
    /// A row's icon slot (glyphs leading-aligned in it, under the section's icon) and the gap from it to the name:
    /// tight, so the name sits close to a narrow branch glyph (user, 2026-11-13).
    static let iconSlot: CGFloat = 20
    static let iconGap: CGFloat = 4
    /// The extra indent of a remote's branches under the remote's row: one step, as GitKraken nests them.
    static let nestedIndent: CGFloat = 16
    /// The section and row icons (GitKraken's): Local is this Mac, Remote the cloud, each branch a branch.
    static let localImage = "laptopcomputer"
    static let remoteImage = "cloud"
    static let branchImage = "arrow.triangle.branch"
}

/// The sidebar of a repo tab: the tab picker across its width (icon and short name; the full name is the tooltip),
/// then its sections as cards in the panel's container, in a scroll view. The cards wait for the refs (capsule skeleton
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
                // The panel's container pads the bottom.
                .padding(.top, SidebarMetrics.cardSpacing)
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
            SidebarSection(title: "Tags", systemImage: "tag", count: refs.tags.count,
                           isExpanded: $session.tagsExpanded) {
                TagRows(session: session, tags: refs.tags)
            }
            .onAppear { UITiming.content("sidebar \(session.url.lastPathComponent)") }
        case (.branches, .idle), (.branches, .loading):
            SidebarSection(title: "Local", systemImage: SidebarMetrics.localImage, count: nil,
                           isExpanded: $session.localExpanded) {
                SkeletonRows(fractions: [0.45, 0.6, 0.35, 0.7, 0.5])
            }
            SidebarSection(title: "Remote", systemImage: SidebarMetrics.remoteImage, count: nil,
                           isExpanded: $session.remoteExpanded) {
                SkeletonRows(fractions: [0.3, 0.55, 0.4])
            }
        case (.tags, .idle), (.tags, .loading):
            SidebarSection(title: "Tags", systemImage: "tag", count: nil, isExpanded: $session.tagsExpanded) {
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
        SidebarSection(title: "Local", systemImage: SidebarMetrics.localImage, count: refs.localBranches.count,
                       isExpanded: $session.localExpanded) {
            if refs.localBranches.isEmpty { EmptyRow(text: "No local branches") }
            ForEach(refs.localBranches, id: \.refName) { branch in
                // As in GitKraken, the checked-out branch shows a check in place of the branch icon.
                BranchRow(session: session, item: .local(branch.name), name: branch.name,
                          systemImage: branch.isHead ? "checkmark" : SidebarMetrics.branchImage) {
                    AheadBehind(branch: branch)
                }
            }
        }
        SidebarSection(title: "Remote", systemImage: SidebarMetrics.remoteImage, count: refs.remoteBranches.count,
                       isExpanded: $session.remoteExpanded) {
            if remotes.isEmpty { EmptyRow(text: "No remotes") }
            ForEach(remotes, id: \.name) { remote in
                RemoteRow(name: remote.name)
                    .contextMenu { MenuEntriesView(entries: RepoMenus.remote(named: remote.name, session)) }
                ForEach(remote.branches, id: \.refName) { branch in
                    BranchRow(session: session, item: .remote(branch.name),
                              name: String(branch.name.dropFirst(remote.name.count + 1)),
                              systemImage: SidebarMetrics.branchImage, indent: SidebarMetrics.nestedIndent) {
                        EmptyView()
                    }
                }
            }
        } accessory: {
            Menu {
                MenuEntriesView(entries: RepoMenus.remotes(session))
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(RowIconButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Remotes")
            .accessibilityLabel("Remote actions")
        }
    }

    /// Remote branches by remote: the remotes in git's order (also those with no fetched branch), then any other remote
    /// a branch names.
    private var remotes: [(name: String, branches: [RemoteBranch])] {
        var order: [String] = session.remotes.map(\.name)
        var groups: [String: [RemoteBranch]] = Dictionary(order.map { ($0, []) }, uniquingKeysWith: { a, _ in a })
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
/// refs load. `accessory` sits at the header's end (the Remote card's menu).
private struct SidebarSection<Content: View, Accessory: View>: View {
    let title: String
    let systemImage: String
    let count: Int?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        SectionCard(title, systemImage: systemImage, count: count, countIsLoading: count == nil,
                    isExpanded: $isExpanded, contentPadding: SidebarMetrics.cardPadding) {
            VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                content()
            }
        } accessory: {
            accessory()
        }
    }
}

extension SidebarSection where Accessory == EmptyView {
    init(title: String, systemImage: String, count: Int?, isExpanded: Binding<Bool>,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, systemImage: systemImage, count: count, isExpanded: isExpanded, content: content,
                  accessory: { EmptyView() })
    }
}

/// The text of an empty section.
private struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.leading, SidebarMetrics.rowLeading)
            .padding(.trailing, 10)
            .frame(height: SidebarItemStyle.height)
    }
}

/// A remote's row in the Remote card ("origin"): a server icon and its name, its branches indented under it. Its
/// context menu renames, removes or re-points the remote.
private struct RemoteRow: View {
    let name: String

    var body: some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Image(systemName: "server.rack")
                .frame(width: SidebarMetrics.iconSlot, alignment: .leading)
            Text(name)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, SidebarMetrics.rowLeading)
        .padding(.trailing, 10)
        .frame(minHeight: SidebarItemStyle.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Remote \(name)")
    }
}

/// A selectable row: icon, name (truncated in the middle), then `trailing` (the ahead/behind counts). A click selects
/// it and jumps the graph to its commit before anything loads; a double-click checks it out, recognized beside the
/// single click (`simultaneousGesture`), so the single click never waits for it. Its context menu is its badge's.
private struct BranchRow<Trailing: View>: View {
    let session: RepoSession
    let item: SidebarItem
    let name: String
    let systemImage: String
    /// Past `SidebarMetrics.rowLeading`: a remote's branches sit one step in from the remote's row.
    var indent: CGFloat = 0
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovered = false

    var body: some View {
        let selected = session.sidebarSelection == item
        HStack(spacing: SidebarMetrics.iconGap) {
            // Leading-aligned in its slot, so every glyph starts where the section header's icon does.
            Image(systemName: systemImage)
                .frame(width: SidebarMetrics.iconSlot, alignment: .leading)
            HStack(spacing: 4) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                trailing()
            }
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        // The look of `SidebarItemStyle`: a neutral capsule when selected, a hover capsule otherwise.
        .padding(.leading, SidebarMetrics.rowLeading + indent)
        .padding(.trailing, 10)
        .frame(minHeight: SidebarItemStyle.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(selected ? Palette.selectedFill : hovered ? Palette.hoverFill : .clear))
        .overlay(Capsule().strokeBorder(selected ? Palette.selectedBorder : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture { session.selectRef(item) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { RepoMenus.checkout(item, session) })
        .contextMenu { MenuEntriesView(entries: RepoMenus.ref(item, session)) }
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { session.selectRef(item) }
        .accessibilityAction(named: "Checkout") { RepoMenus.checkout(item, session) }
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
            HStack(spacing: SidebarMetrics.iconGap) {
                SkeletonLine(width: 14, height: 14)
                    .frame(width: SidebarMetrics.iconSlot, alignment: .leading)
                SkeletonLine(fraction: fractions[index], height: 11)
            }
            .padding(.leading, SidebarMetrics.rowLeading)
            .padding(.trailing, 10)
            .frame(height: SidebarItemStyle.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
