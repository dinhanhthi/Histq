// A repo tab's three panels (Rex style: solid cards on the window glass with a small gap): the sidebar, the commit
// graph (or the open file's diff, or a conflicted file's conflict editor) under the operation banner while a merge,
// rebase, cherry-pick or revert is in progress, and the detail. The two gaps are draggable dividers; the
// side panels' widths are saved in `PrefKey.panelWidths`.
import HistqCore
import SwiftUI

/// Sizes of the repo layout. The middle panel takes what the side panels leave. The window's minimum size
/// (`minimumWindowSize`) fits the three panels at their minimums.
enum RepoLayoutMetrics {
    /// Between two panels: the divider's grab area.
    static let gap: CGFloat = 8
    /// From the window's edges (the header row is above).
    static let inset: CGFloat = 8
    static let sidebar: ClosedRange<CGFloat> = 200...420
    static let detail: ClosedRange<CGFloat> = 320...640
    static let graphMin: CGFloat = 360
    /// The panels' row: both insets and both gaps.
    static let chrome: CGFloat = 2 * inset + 2 * gap
    /// 200 + 360 + 320 + 32 = 912 wide; 520 tall: the header row and about 15 list rows.
    static let minimumWindowSize = CGSize(
        width: sidebar.lowerBound + graphMin + detail.lowerBound + chrome, height: 520)
    fileprivate static let defaults = PanelWidths(sidebar: 240, detail: 360)
}

/// The side panels' widths, stored as "sidebar,detail" in `PrefKey.panelWidths`.
private struct PanelWidths: Equatable {
    var sidebar: CGFloat
    var detail: CGFloat

    init(sidebar: CGFloat, detail: CGFloat) {
        self.sidebar = sidebar
        self.detail = detail
    }

    /// Decodes the stored value; the defaults when empty or malformed.
    init(encoded: String) {
        let values = encoded.split(separator: ",").compactMap { Double($0) }
        self = values.count == 2 ? PanelWidths(sidebar: values[0], detail: values[1]) : RepoLayoutMetrics.defaults
    }

    var encoded: String { "\(Int(sidebar.rounded())),\(Int(detail.rounded()))" }

    /// Clamped to their ranges, then fitted in `available` (the width of the three panels) so the middle panel
    /// keeps `graphMin`: the side panels give up their width above their minimums in proportion to it. Below the sum
    /// of the minimums (a screen smaller than the window's minimum), all three shrink in proportion to them.
    func fitted(in available: CGFloat) -> PanelWidths {
        let sidebar = sidebar.clamped(to: RepoLayoutMetrics.sidebar)
        let detail = detail.clamped(to: RepoLayoutMetrics.detail)
        let overflow = sidebar + detail + RepoLayoutMetrics.graphMin - available
        guard overflow > 0 else { return PanelWidths(sidebar: sidebar, detail: detail) }
        let sidebarSpare = sidebar - RepoLayoutMetrics.sidebar.lowerBound
        let detailSpare = detail - RepoLayoutMetrics.detail.lowerBound
        let spare = sidebarSpare + detailSpare
        if overflow <= spare {
            return PanelWidths(sidebar: sidebar - overflow * sidebarSpare / spare,
                               detail: detail - overflow * detailSpare / spare)
        }
        let minimums = RepoLayoutMetrics.sidebar.lowerBound + RepoLayoutMetrics.detail.lowerBound + RepoLayoutMetrics.graphMin
        let scale = max(available, 0) / minimums
        return PanelWidths(sidebar: RepoLayoutMetrics.sidebar.lowerBound * scale,
                           detail: RepoLayoutMetrics.detail.lowerBound * scale)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

/// A repo tab: the error banner of a failed operation (when there is one), then sidebar | commit list | detail. Each
/// panel waits for its own data (the refs, the log, the selected detail) and shows its placeholder until then; a tab
/// switch shows the detail's placeholder in the same frame.
struct RepoLayoutView: View {
    let session: RepoSession
    @AppStorage(PrefKey.panelWidths.rawValue, store: Preferences.defaults) private var storedWidths = ""
    /// The widths while a divider is dragged; written to `storedWidths` when the drag ends.
    @State private var dragWidths: PanelWidths?
    /// The widths when the drag began.
    @State private var dragStart: PanelWidths?

    private enum DividerSide { case sidebar, detail }

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.width - RepoLayoutMetrics.chrome
            let widths = (dragWidths ?? PanelWidths(encoded: storedWidths)).fitted(in: available)
            VStack(spacing: SectionCardMetrics.spacing) {
                if let failure = session.failure {
                    ActionErrorBanner(session: session, failure: failure)
                }
                panels(widths: widths, available: available)
            }
            .padding([.horizontal, .bottom], RepoLayoutMetrics.inset)
        }
        .operationDialogs(session: session)
    }

    /// The three panels and their dividers.
    private func panels(widths: PanelWidths, available: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Its sections are cards of their own on the window glass, not one panel card.
            SidebarView(session: session)
                .frame(width: widths.sidebar)
            divider(.sidebar, widths: widths, available: available)
            VStack(spacing: SectionCardMetrics.spacing) {
                // Reads the operation itself, so a status read redraws the banner and not the panels.
                OperationBanner(session: session)
                panel2
            }
            .frame(maxWidth: .infinity)
            divider(.detail, widths: widths, available: available)
            DetailPanel(session: session)
                .frame(width: widths.detail)
        }
    }

    /// The graph, with the open file's diff or conflict editor over it.
    private var panel2: some View {
        ZStack {
            // The graph stays mounted under an open file, so Esc brings it back as it was (scroll, selection)
            // and opening a file costs no teardown in the click's frame.
            let fileOpen = session.openFile != nil
            CommitListPanel(session: session)
                .opacity(fileOpen ? 0 : 1)
                .allowsHitTesting(!fileOpen)
                .accessibilityHidden(fileOpen)
            if let target = session.openFile {
                if target.isConflict {
                    ConflictEditorView(session: session, target: target)
                } else {
                    DiffView(session: session, target: target)
                }
            }
        }
    }

    /// The gap between two panels: drag it to resize the side panel next to it.
    private func divider(_ side: DividerSide, widths: PanelWidths, available: CGFloat) -> some View {
        Color.clear
            .frame(width: RepoLayoutMetrics.gap)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? widths
                        if dragStart == nil { dragStart = widths }
                        var next = start
                        switch side {
                        case .sidebar:
                            let limit = available - start.detail - RepoLayoutMetrics.graphMin
                            next.sidebar = min(start.sidebar + drag.translation.width, limit)
                                .clamped(to: RepoLayoutMetrics.sidebar)
                        case .detail:
                            let limit = available - start.sidebar - RepoLayoutMetrics.graphMin
                            next.detail = min(start.detail - drag.translation.width, limit)
                                .clamped(to: RepoLayoutMetrics.detail)
                        }
                        dragWidths = next
                    }
                    .onEnded { _ in
                        if let dragWidths { storedWidths = dragWidths.encoded }
                        dragWidths = nil
                        dragStart = nil
                    })
            .accessibilityHidden(true)
    }
}

// MARK: - Panel 2: the commit graph

/// The commit graph in one card without a title row: the graph's column titles are its header. Skeleton rows (under a
/// skeleton header) while the first page loads, then `GraphView` with every row (the WIP and stash rows above the
/// commits).
private struct CommitListPanel: View {
    let session: RepoSession
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yyyy @ h:mm a"
    @AppStorage(PrefKey.rowDensity.rawValue, store: Preferences.defaults) private var rowDensity = "regular"

    var body: some View {
        SectionCard(nil, contentPadding: 0) {
            Group {
                switch session.log {
                case .idle, .loading:
                    SkeletonCommitRows()
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Loading")
                case .loaded(let log):
                    // A click selects through the session (the detail switches in the same frame); a double-click
                    // checks out; a right-click opens the row's or the badge's menu; a badge dropped on another opens
                    // Merge / Rebase / Fast-forward.
                    GraphView(log: log, refs: session.refs.value, status: session.status.value,
                              dateFormat: dateFormat, rowDensity: rowDensity, selection: session.graphSelection,
                              onSelect: { [session] items in session.selectGraph(items) },
                              onActivate: { [session] item in RepoMenus.activate(item, session: session) },
                              menuEntries: { [session] item, badge in
                                  if let ref = badge?.sidebarItem { return RepoMenus.ref(ref, session) }
                                  return RepoMenus.entries(for: item, session: session)
                              },
                              dropEntries: { [session] source, target in
                                  guard let source = source.sidebarItem, let target = target.sidebarItem else { return [] }
                                  return RepoMenus.drop(source, onto: target, session)
                              })
                        .onAppear { UITiming.content("commits \(session.url.lastPathComponent)") }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The graph's shape while the log loads: the column titles' row and a hairline, then rows of node, subject (varied
/// widths), author and date.
private struct SkeletonCommitRows: View {
    private static let subjects: [CGFloat] = [0.7, 0.5, 0.82, 0.62, 0.45, 0.75, 0.58, 0.66, 0.4, 0.72]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SkeletonLine(width: 72, height: 8)
                SkeletonLine(width: 40, height: 8)
                SkeletonLine(fraction: 0.3, height: 8)
                SkeletonLine(width: 44, height: 8)
                SkeletonLine(width: 96, height: 8)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            Divider()
            ForEach(Self.subjects.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    SkeletonLine(width: 16, height: 16)
                        .frame(width: 24)
                    SkeletonLine(fraction: Self.subjects[index], height: 11)
                    SkeletonLine(width: index.isMultiple(of: 3) ? 64 : 84, height: 11)
                    SkeletonLine(width: 96, height: 11)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
            }
        }
    }
}

// MARK: - Panel 3: the detail

/// The selected detail, its parts in cards: the WIP panel, a commit or stash, a multi-selection count, or the
/// overview cards (an unborn branch). Until it loads, the selection's cards hold skeleton rows (`PlaceholderCard`:
/// spinner after 150 ms, the `placeholder` line); then the `content` line. All carry `session.selectDetail`.
private struct DetailPanel: View {
    let session: RepoSession
    @Environment(WindowModel.self) private var model

    var body: some View {
        Group {
            switch session.detail {
            case .idle, .loading:
                PlaceholderCard(
                    token: session.selectToken, detail: session.selectDetail,
                    isCurrent: { [model, session] in model.selectedSession === session }
                ) {
                    placeholder
                }
            case .loaded(let detail):
                loaded(detail)
                    .onAppear { UITiming.content(session.selectDetail) }
            case .failed(let message):
                FailedCard(message: message, path: session.url.path)
                    .onAppear { UITiming.content("\(session.selectDetail) failed") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The loading selection's cards. A tab that just opened shows the WIP's while its status is unknown or dirty.
    @ViewBuilder private var placeholder: some View {
        switch session.selection {
        case .wip:
            WIPPlaceholder(hasConflicts: hasConflicts)
        case .commit, .stash, .ref:
            CommitDetailPlaceholder()
        case .multiple(let count):
            MultipleSelectionCard(count: count)
        case .overview:
            if session.status.value?.entries.isEmpty == true {
                CommitDetailPlaceholder()
            } else {
                WIPPlaceholder(hasConflicts: hasConflicts)
            }
        }
    }

    /// The last status had conflicted files: the WIP placeholder keeps the Conflicted card's place.
    private var hasConflicts: Bool {
        session.status.value?.conflicted.isEmpty == false
    }

    @ViewBuilder private func loaded(_ detail: RepoSession.Detail) -> some View {
        switch detail {
        case .wip:
            WIPPanel(session: session)
        case .commit(let commit):
            CommitDetailPanel(session: session, commit: commit)
        case .multiple(let count):
            MultipleSelectionCard(count: count)
        case .overview:
            ScrollView {
                OverviewCards(branch: branch, path: session.url.path, commits: commits, status: session.status.value)
            }
        }
    }

    private var branch: String {
        switch session.refs.value?.head {
        case .branch(let name, _), .unborn(let name): name
        case .detached(let commit): "Detached at \(commit.prefix(7))"
        case nil: "—"
        }
    }

    private var commits: String {
        switch session.log {
        case .loaded(let log): "\(log.commits.count)\(log.isComplete ? "" : "+") commits on all branches"
        case .failed: "History unavailable"
        case .idle, .loading: "Counting commits…"
        }
    }
}

/// The overview's cards: Branch, History, Working tree. A nil value draws its skeleton line in the same place, so
/// the placeholder has the loaded cards' footprint.
private struct OverviewCards: View {
    let branch: String?
    let path: String
    let commits: String?
    let status: WorkingStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: SectionCardMetrics.spacing) {
            SectionCard("Branch", systemImage: "arrow.triangle.branch") {
                VStack(alignment: .leading, spacing: 4) {
                    if let branch {
                        Text(branch)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        SkeletonLine(width: 96, height: 16).frame(height: 24)
                    }
                    Text(path)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            SectionCard("History", systemImage: "clock") {
                if let commits {
                    Text(commits).monospacedDigit()
                } else {
                    SkeletonLine(fraction: 0.6, height: 12).frame(height: 16)
                }
            }
            SectionCard("Working tree", systemImage: "doc.on.doc", count: status.map(Self.changeCount),
                        countIsLoading: status == nil) {
                VStack(alignment: .leading, spacing: 2) {
                    CountRow(title: "Staged", value: status?.staged.count, width: 0.35)
                    CountRow(title: "Unstaged", value: status?.unstaged.count, width: 0.45)
                    CountRow(title: "Untracked", value: status?.untracked.count, width: 0.4)
                    if let conflicted = status?.conflicted.count, conflicted > 0 {
                        CountRow(title: "Conflicted", value: conflicted, width: 0.4)
                    }
                }
            }
        }
    }

    private static func changeCount(_ status: WorkingStatus) -> Int {
        status.staged.count + status.unstaged.count + status.untracked.count + status.conflicted.count
    }
}

/// A title and a count; a skeleton line of `width` (a fraction of the row) while the value is nil.
private struct CountRow: View {
    let title: String
    let value: Int?
    let width: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            if let value {
                Text(title)
                Spacer(minLength: 8)
                Text("\(value)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                SkeletonLine(fraction: width, height: 12)
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .combine)
    }
}

/// The overview when the repo cannot be read (not a repository, git missing).
private struct FailedCard: View {
    let message: String
    let path: String

    var body: some View {
        SectionCard("Overview", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(path)
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
