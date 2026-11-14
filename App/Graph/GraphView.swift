// The commit graph: an NSTableView with gk's columns (BRANCH / TAG, GRAPH, COMMIT MESSAGE, AUTHOR, COMMIT DATE / TIME).
// Rows: the WIP row (when the working tree has changes), a WIP row per other worktree with changes (labeled with its
// folder's name; a click opens it in a tab), the stash rows, then the commits, laid out by `GraphLayout`.
// The table only asks for the rows on screen, so its cost does not grow with the log: a later page of the same load is
// inserted as rows, a new load reloads. A click selects at once (`action`); a double-click calls the checkout hook
// (`doubleAction`) without delaying the single click. A click on a branch badge's pull request chip opens that pull
// request at mouse down instead of selecting the row.
import AppKit
import HistqCore
import SwiftUI

/// What a graph row stands for: what the selection callback and the double-click hook get.
enum GraphItem: Hashable, Sendable {
    case wip
    /// A stash, by its commit hash.
    case stash(String)
    case commit(String)
    /// Another worktree's WIP row, by the worktree's path. Never a selection: a click opens the worktree in a tab.
    case worktree(String)
}

/// The graph's columns, in gk's order. Widths are resizable and saved in `PrefKey.graphColumnWidths`; the message
/// column takes what the others leave.
enum GraphColumn: String, CaseIterable {
    case refs, graph, message, author, date

    var title: String {
        switch self {
        case .refs: "Branch / Tag"
        case .graph: "Graph"
        case .message: "Commit message"
        case .author: "Author"
        case .date: "Commit date / time"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .refs: 116
        case .graph: 108
        case .message: 240
        case .author: 76
        // Fits "12/31/25 @ 23:00", the default format since 7.5.
        case .date: 120
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .refs: 40
        case .graph: 32
        case .message: 80
        case .author: 40
        case .date: 60
        }
    }

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    /// Decodes `PrefKey.graphColumnWidths` ("refs:124,graph:120,…"); unknown or malformed entries are skipped.
    static func storedWidths(_ encoded: String) -> [GraphColumn: CGFloat] {
        var widths: [GraphColumn: CGFloat] = [:]
        for entry in encoded.split(separator: ",") {
            let parts = entry.split(separator: ":")
            guard parts.count == 2, let column = GraphColumn(rawValue: String(parts[0])), let width = Double(parts[1])
            else { continue }
            widths[column] = max(column.minWidth, width)
        }
        return widths
    }
}

/// The graph table. `log` gives the rows; `refs` the badges; `status` the WIP row's counts. `dateFormat` and
/// `rowDensity` are `PrefKey.dateFormat` and `PrefKey.rowDensity`. `onSelect` gets the selected rows (in row order) as
/// soon as the selection changes (a click, ⌘/⇧-click, the arrow keys); `onActivate` gets a double-clicked row.
/// `selection` is the selection the table follows: a new one (a parent jump) is selected and scrolled to, without an
/// `onSelect` echo. ⌘Z / ⇧⌘Z while the table has the focus ask `canUndo` and run `onUndo` (`redo` true for Redo);
/// a text field keeps its own undo, since its field editor answers first.
struct GraphView: NSViewRepresentable {
    let log: LogSnapshot
    let refs: Refs?
    let status: WorkingStatus?
    let dateFormat: String
    let rowDensity: String
    var selection: [GraphItem] = []
    var onSelect: @MainActor ([GraphItem]) -> Void = { _ in }
    var onActivate: @MainActor (GraphItem) -> Void = { _ in }
    /// The context menu of a row; `badge` is the ref badge under the pointer, if any.
    var menuEntries: @MainActor (GraphItem, RefBadge?) -> [MenuEntry] = { _, _ in [] }
    /// The menu of a branch badge dropped on another (source, target).
    var dropEntries: @MainActor (RefBadge, RefBadge) -> [MenuEntry] = { _, _ in [] }
    var canUndo: @MainActor (_ redo: Bool) -> Bool = { _ in false }
    var onUndo: @MainActor (_ redo: Bool) -> Void = { _ in }
    /// A click on another worktree's WIP row, with its path (arrow keys passing over the row do not call it).
    var onOpenWorktree: @MainActor (String) -> Void = { _ in }
    /// The open pull requests by remote branch (`GitHubStore.branchPullRequests`): their chips on the branch badges.
    var pullRequests: [String: RefBadge.PullRequest] = [:]
    /// A click on a pull request chip, with its number.
    var onOpenPullRequest: @MainActor (Int) -> Void = { _ in }

    func makeCoordinator() -> GraphTableController { GraphTableController() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GraphTableView()
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.headerView = GraphHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 26))
        table.cornerView = nil

        let stored = GraphColumn.storedWidths(
            Preferences.defaults.string(forKey: PrefKey.graphColumnWidths.rawValue) ?? "")
        for column in GraphColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.headerCell = GraphHeaderCell(textCell: column.title)
            tableColumn.minWidth = column.minWidth
            tableColumn.width = stored[column] ?? column.defaultWidth
            // Only the message column follows the table's width; the others keep theirs.
            tableColumn.resizingMask = column == .message ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(tableColumn)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        context.coordinator.attach(table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }
}

/// The graph's table: the message column takes the width the other columns leave (at least its minimum), so the
/// columns always fill the card and the date column stays on screen. A right-click asks the controller for the row's
/// (or the badge's) menu; the mouse-down point tells a badge drag from a row drag.
final class GraphTableView: NSTableView {
    /// Where the last mouse down was, in the table: the drag source checks it is on a branch badge.
    private(set) var mouseDownPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A pull request chip opens its pull request at once; the row's selection, its detail and a badge drag are
        // left alone (a row select would close the pull request again).
        if event.clickCount == 1, (delegate as? GraphTableController)?.openPullRequest(at: point) == true { return }
        mouseDownPoint = point
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        (delegate as? GraphTableController)?.menu(at: convert(event.locationInWindow, from: nil))
    }

    // Edit › Undo / Redo (⌘Z / ⇧⌘Z) reach the table only while it is the first responder.

    @objc func undo(_ sender: Any?) {
        (delegate as? GraphTableController)?.history(redo: false)
    }

    @objc func redo(_ sender: Any?) {
        (delegate as? GraphTableController)?.history(redo: true)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): (delegate as? GraphTableController)?.canHistory(redo: false) ?? false
        case #selector(redo(_:)): (delegate as? GraphTableController)?.canHistory(redo: true) ?? false
        default: super.validateUserInterfaceItem(item)
        }
    }

    override func tile() {
        super.tile()
        guard let clip = enclosingScrollView?.contentView,
              let message = tableColumn(withIdentifier: GraphColumn.message.identifier)
        else { return }
        let others = tableColumns.reduce(0) { $0 + ($1 === message ? 0 : $1.width) }
        let width = max(message.minWidth, clip.bounds.width - others)
        if abs(message.width - width) > 0.5 { message.width = width }
    }
}

/// The table's data source and delegate. It keeps the snapshot it shows and compares only generations and counts, so
/// an update costs the same for 50 commits and for 50,000.
@MainActor
final class GraphTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var table: NSTableView?
    /// The latest view, for its callbacks.
    private var view: GraphView?
    private var log = LogSnapshot()
    private var refs: Refs?
    private var pullRequests: [String: RefBadge.PullRequest] = [:]
    private var badges: [String: [RefBadge]] = [:]
    private var wipDetail: String?
    private var dateFormat: String?
    private let formatter = DateFormatter()
    private var metrics = GraphMetrics(density: "regular")
    /// The last selection sent to `onSelect`: a click reports at mouse down (selection change) and again at mouse up
    /// (`action`), only the first goes out.
    private var reported: [GraphItem] = []
    /// While `update` runs: a selection change it causes (a reload, `syncSelection`) is not a user's.
    private var isUpdating = false
    /// The last `GraphView.selection`; a new one is scrolled to once its rows exist.
    private var wanted: [GraphItem] = []
    private var needsScroll = false

    private static let rowViewID = NSUserInterfaceItemIdentifier("graphRow")
    /// The pasteboard type of a dragged branch badge (its `SidebarItem`, as `local:<name>` / `remote:<name>`).
    private static let badgeType = NSPasteboard.PasteboardType("com.math2it.histq.branch-badge")
    /// The badge being dragged.
    private var dragged: RefBadge?

    func attach(_ table: NSTableView) {
        self.table = table
        table.rowHeight = metrics.rowHeight
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.doubleAction = #selector(doubleClicked(_:))
        table.registerForDraggedTypes([Self.badgeType])
        table.setDraggingSourceOperationMask(.generic, forLocal: true)
        NotificationCenter.default.addObserver(
            self, selector: #selector(avatarsChanged(_:)), name: AvatarStore.didChange, object: nil)
    }

    func update(_ view: GraphView) {
        self.view = view
        isUpdating = true
        updateRows(view)
        syncSelection(view.selection)
        isUpdating = false
    }

    private func updateRows(_ view: GraphView) {
        guard let table else { return }
        var reloadVisible = false

        let newMetrics = GraphMetrics(density: view.rowDensity)
        if newMetrics != metrics {
            metrics = newMetrics
            table.rowHeight = metrics.rowHeight
            reloadVisible = true
        }
        if view.dateFormat != dateFormat {
            dateFormat = view.dateFormat
            // The user's language without their 24-hour override, which would turn `h:mm a` into `HH:mm`: the
            // preference's format is applied as written.
            formatter.locale = Locale(identifier: Locale.current.identifier)
            formatter.dateFormat = view.dateFormat
            reloadVisible = true
        }
        if view.refs != refs || view.pullRequests != pullRequests {
            refs = view.refs
            pullRequests = view.pullRequests
            badges = view.refs.map { RefBadge.badges(for: $0, pullRequests: pullRequests) } ?? [:]
            reloadVisible = true
        }
        let wip = view.status.map(Self.wipDetail)
        if wip != wipDetail {
            wipDetail = wip
            reloadVisible = true
        }

        let old = log
        let new = view.log
        if new.generation != old.generation || new.syntheticRows.count != old.syntheticRows.count
            || new.commits.count < old.commits.count
        {
            // A new load (or a new layout): every row may have changed. A reload of a log already on screen keeps the
            // top visible row where it was (rows above it may have come or gone) and does not scroll to the selection.
            let anchor = old.syntheticRows.count + old.commits.count > 0 ? scrollAnchor(table) : nil
            log = new
            table.reloadData()
            if let anchor {
                restoreScroll(anchor, in: table)
                needsScroll = false
            }
            return
        }
        log = new
        if new.commits.count > old.commits.count {
            // Later pages of the same load: the rows above are unchanged.
            let first = old.syntheticRows.count + old.commits.count
            table.insertRows(at: IndexSet(integersIn: first..<rowCount), withAnimation: [])
        }
        if reloadVisible {
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                             columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
    }

    private var rowCount: Int { log.syntheticRows.count + log.commits.count }

    /// The rows on screen before a reload, top first, with their items; `atTop` when the list is scrolled to its top.
    private struct ScrollAnchor {
        let rows: [(row: Int, item: GraphItem)]
        let atTop: Bool
    }

    private func scrollAnchor(_ table: NSTableView) -> ScrollAnchor? {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return nil }
        let rows = (visible.location..<NSMaxRange(visible)).compactMap { row in item(at: row).map { (row, $0) } }
        // With the header over the rows, the top is at a negative y.
        return ScrollAnchor(rows: rows, atTop: table.visibleRect.minY <= 0.5)
    }

    /// Scrolls by as much as the first anchor row that still exists moved, so it stays at the same place on screen. At
    /// the top the list stays at the top (a new WIP row shows); when every anchor row is gone the offset is kept.
    private func restoreScroll(_ anchor: ScrollAnchor, in table: NSTableView) {
        guard !anchor.atTop, let scroll = table.enclosingScrollView else { return }
        guard let moved = anchor.rows.lazy.compactMap({ old in self.row(of: old.item).map { (old.row, $0) } }).first,
              moved.0 != moved.1
        else { return }
        table.noteNumberOfRowsChanged()
        let clip = scroll.contentView
        var bounds = clip.bounds
        // Every row has the same height.
        bounds.origin.y += CGFloat(moved.1 - moved.0) * (table.rowHeight + table.intercellSpacing.height)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// "3 unstaged · 2 staged": the WIP row's counts (untracked and conflicted files count as unstaged).
    private static func wipDetail(_ status: WorkingStatus) -> String {
        WorktreeChanges(status).detail
    }

    // MARK: Rows

    private func item(at row: Int) -> GraphItem? {
        guard row >= 0 else { return nil }
        if row < log.syntheticRows.count {
            let synthetic = log.synthetic[row]
            switch synthetic.kind {
            case .wip: return .wip
            case .stash: return .stash(synthetic.id)
            case .worktreeWIP: return .worktree(synthetic.id)
            }
        }
        let index = row - log.syntheticRows.count
        return index < log.commits.count ? .commit(log.commits[index].hash) : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let view = tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? GraphRowView { return view }
        let view = GraphRowView()
        view.identifier = Self.rowViewID
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = GraphColumn(rawValue: tableColumn.identifier.rawValue),
              row >= 0, row < rowCount
        else { return nil }
        let isSynthetic = row < log.syntheticRows.count
        let graphRow = isSynthetic ? log.syntheticRows[row] : log.rows[row - log.syntheticRows.count]
        let commit = isSynthetic ? nil : log.commits[row - log.syntheticRows.count]
        let synthetic = isSynthetic ? log.synthetic[row] : nil

        switch column {
        case .refs:
            let cell = reuse(tableView, column) { RefBadgeCellView() }
            if let worktree = worktree(synthetic) {
                cell.badges = [RefBadge(kind: .worktree, name: worktree.name)]
            } else {
                cell.badges = commit.flatMap { badges[$0.hash] } ?? []
            }
            cell.color = graphRow.color
            cell.metrics = metrics
            cell.needsDisplay = true
            return cell
        case .graph:
            let cell = reuse(tableView, column) { GraphCellView() }
            cell.row = graphRow
            cell.metrics = metrics
            cell.avatar = commit.flatMap { $0.isMerge ? nil : avatar(for: $0, in: tableView) }
            cell.hasRefs = commit.map { badges[$0.hash] != nil } ?? false
            if let commit {
                cell.node = commit.isMerge
                    ? .merge : .commit(initials: GraphRowDrawing.initials(of: commit.authorName))
            } else {
                cell.node = synthetic?.kind == .stash ? .stash : .wip
            }
            cell.needsDisplay = true
            return cell
        case .message:
            let cell = reuse(tableView, column) { GraphTextCellView() }
            cell.detail = nil
            if let commit {
                cell.text = commit.subject
                cell.tone = .primary
                cell.isItalic = false
            } else if synthetic?.kind == .stash {
                cell.text = stash(synthetic?.id)?.message ?? "Stash"
                cell.tone = .secondary
                cell.isItalic = true
            } else if let worktree = worktree(synthetic) {
                cell.text = "// WIP"
                cell.detail = worktree.changes.map(\.detail).flatMap { $0.isEmpty ? nil : $0 }
                cell.tone = .secondary
                cell.isItalic = true
            } else {
                cell.text = "// WIP"
                cell.detail = wipDetail.flatMap { $0.isEmpty ? nil : $0 }
                cell.tone = .primary
                cell.isItalic = true
            }
            cell.needsDisplay = true
            return cell
        case .author:
            let cell = reuse(tableView, column) { GraphTextCellView() }
            cell.text = commit?.authorName ?? ""
            cell.detail = nil
            cell.tone = .secondary
            cell.isItalic = false
            cell.needsDisplay = true
            return cell
        case .date:
            let cell = reuse(tableView, column) { GraphTextCellView() }
            // Formatted only for the rows on screen.
            let date = commit?.authorDate ?? (synthetic?.kind == .stash ? stash(synthetic?.id)?.date : nil)
            cell.text = date.map(formatter.string(from:)) ?? ""
            cell.detail = nil
            cell.tone = .secondary
            cell.isItalic = false
            cell.needsDisplay = true
            return cell
        }
    }

    /// The node's avatar, sized for the node at the window's backing scale.
    private func avatar(for commit: Commit, in table: NSTableView) -> NSImage? {
        let scale = table.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Int((metrics.nodeDiameter * scale).rounded(.up))
        return AvatarStore.shared.avatar(email: commit.authorEmail, name: commit.authorName, pixels: pixels)
    }

    /// An avatar arrived (redraw the visible nodes of its author) or the mode changed (redraw every visible node).
    @objc private func avatarsChanged(_ notification: Notification) {
        guard let table else { return }
        let column = table.column(withIdentifier: GraphColumn.graph.identifier)
        let visible = table.rows(in: table.visibleRect)
        guard column >= 0, visible.length > 0 else { return }
        let changed = notification.userInfo?[AvatarStore.emailKey] as? String
        for row in visible.location..<NSMaxRange(visible) {
            let index = row - log.syntheticRows.count
            guard index >= 0, index < log.commits.count,
                  let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? GraphCellView
            else { continue }
            let commit = log.commits[index]
            if commit.isMerge { continue }
            if let changed, !AvatarStore.matches(email: commit.authorEmail, name: commit.authorName, changed: changed) {
                continue
            }
            cell.avatar = avatar(for: commit, in: table)
            cell.needsDisplay = true
        }
    }

    private func stash(_ hash: String?) -> Stash? {
        log.stashes.first { $0.hash == hash }
    }

    /// The other worktree of a worktree WIP row.
    private func worktree(_ synthetic: GraphSyntheticRow?) -> WorktreeInfo? {
        guard let synthetic, synthetic.kind == .worktreeWIP else { return nil }
        return log.worktrees.first { $0.path == synthetic.id }
    }

    private func reuse<Cell: NSView>(_ table: NSTableView, _ column: GraphColumn, make: () -> Cell) -> Cell {
        if let cell = table.makeView(withIdentifier: column.identifier, owner: nil) as? Cell { return cell }
        let cell = make()
        cell.identifier = column.identifier
        return cell
    }

    // MARK: Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        reportSelection()
    }

    /// A click: the selection already changed at mouse down; a click that did not change it reports nothing new. A
    /// click on another worktree's WIP row opens that worktree (only a click: arrows never open tabs).
    @objc func clicked(_ sender: Any?) {
        reportSelection()
        guard let table, case .worktree(let path)? = item(at: table.clickedRow),
              table.selectedRowIndexes == IndexSet(integer: table.clickedRow)
        else { return }
        view?.onOpenWorktree(path)
    }

    /// Checks out the double-clicked row (the hook); the first click of the pair has already selected it.
    @objc func doubleClicked(_ sender: Any?) {
        guard let table, let item = item(at: table.clickedRow) else { return }
        view?.onActivate(item)
    }

    /// Selects the rows of `selection` when the table shows another selection (a parent jump, the default selection,
    /// rows moved by a reload), and scrolls to a new one. `reported` takes it first, so it is not sent back.
    private func syncSelection(_ selection: [GraphItem]) {
        guard let table else { return }
        if selection != wanted {
            wanted = selection
            needsScroll = true
        }
        let current = table.selectedRowIndexes.compactMap(item(at:))
        reported = selection
        guard current != selection else {
            needsScroll = false
            return
        }
        let rows = IndexSet(selection.compactMap(row(of:)))
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if needsScroll, let first = rows.first {
            table.scrollRowToVisible(first)
            needsScroll = false
        }
    }

    private func row(of item: GraphItem) -> Int? {
        switch item {
        case .wip:
            return log.synthetic.firstIndex { $0.kind == .wip }
        case .stash(let hash):
            return log.synthetic.firstIndex { $0.kind == .stash && $0.id == hash }
        case .commit(let hash):
            return log.commits.firstIndex { $0.hash == hash }.map { $0 + log.syntheticRows.count }
        case .worktree(let path):
            return log.synthetic.firstIndex { $0.kind == .worktreeWIP && $0.id == path }
        }
    }

    /// Worktree rows are left out: a selection of only those (a click on one, an arrow onto one) reports nothing and
    /// the detail stays.
    private func reportSelection() {
        guard let table, !isUpdating else { return }
        let items = table.selectedRowIndexes.compactMap(item(at:)).filter {
            if case .worktree = $0 { false } else { true }
        }
        guard items != reported, !items.isEmpty || table.selectedRowIndexes.isEmpty else { return }
        reported = items
        view?.onSelect(items)
    }

    // MARK: Undo

    func canHistory(redo: Bool) -> Bool { view?.canUndo(redo) ?? false }

    func history(redo: Bool) {
        guard canHistory(redo: redo) else { return }
        view?.onUndo(redo)
    }

    // MARK: Menus

    /// The menu of the row at `point` (in the table), with the badge under it; nil outside the rows.
    func menu(at point: NSPoint) -> NSMenu? {
        guard let table, let view else { return nil }
        let row = table.row(at: point)
        guard let item = item(at: row) else { return nil }
        let entries = view.menuEntries(item, badge(at: point))
        return entries.isEmpty ? nil : MenuBuilder.menu(entries)
    }

    /// Opens the pull request whose chip is at `point` (in the table); false when there is none.
    func openPullRequest(at point: NSPoint) -> Bool {
        guard let table, let view, let cell = cell(at: point),
              let pull = cell.pullRequest(at: cell.convert(point, from: table))
        else { return false }
        view.onOpenPullRequest(pull.number)
        return true
    }

    /// The badge drawn at `point` (in the table).
    private func badge(at point: NSPoint) -> RefBadge? {
        guard let table, let cell = cell(at: point) else { return nil }
        return cell.badge(at: cell.convert(point, from: table))
    }

    // MARK: Drag and drop

    /// Only a branch badge drags (its row would otherwise start a row drag, which the graph does not have): a drag
    /// anywhere else keeps the table's own drag-to-select.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let point = (tableView as? GraphTableView)?.mouseDownPoint, tableView.row(at: point) == row,
              let badge = badge(at: point), let item = badge.sidebarItem, item.branchName != nil
        else { return nil }
        dragged = badge
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(badge.name, forType: Self.badgeType)
        return pasteboardItem
    }

    /// The drag image is the badge alone, under the pointer.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet)
    {
        guard let badge = dragged, let point = (tableView as? GraphTableView)?.mouseDownPoint,
              let cell = cell(at: point)
        else { return }
        let image = cell.dragImage(of: badge, scale: tableView.window?.backingScaleFactor ?? 2)
        session.draggingFormation = .none
        session.enumerateDraggingItems(
            options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]
        ) { item, _, _ in
            let origin = NSPoint(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2)
            item.setDraggingFrame(NSRect(origin: origin, size: image.size), contents: image)
        }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation)
    {
        dragged = nil
    }

    /// A drop is only on another branch badge.
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation
    {
        let point = tableView.convert(info.draggingLocation, from: nil)
        guard dropTarget(at: point) != nil else { return [] }
        tableView.setDropRow(tableView.row(at: point), dropOperation: .on)
        return .generic
    }

    /// Opens the Merge / Rebase / Fast-forward menu where the badge was dropped, after the drag has ended.
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool
    {
        let point = tableView.convert(info.draggingLocation, from: nil)
        guard let source = dragged, let target = dropTarget(at: point), let view else { return false }
        let entries = view.dropEntries(source, target)
        guard !entries.isEmpty else { return false }
        let menu = MenuBuilder.menu(entries)
        DispatchQueue.main.async { [weak tableView] in
            guard let tableView else { return }
            menu.popUp(positioning: nil, at: point, in: tableView)
        }
        return true
    }

    /// The branch badge under `point` that the dragged badge can be dropped on.
    private func dropTarget(at point: NSPoint) -> RefBadge? {
        guard let source = dragged, let target = badge(at: point), target != source,
              target.sidebarItem?.branchName != nil
        else { return nil }
        return target
    }

    private func cell(at point: NSPoint) -> RefBadgeCellView? {
        guard let table else { return nil }
        let column = table.column(withIdentifier: GraphColumn.refs.identifier)
        let row = table.row(at: point)
        guard row >= 0, column >= 0, table.column(at: point) == column else { return nil }
        return table.view(atColumn: column, row: row, makeIfNecessary: false) as? RefBadgeCellView
    }

    // MARK: Columns

    /// Saves the widths after the user drags a column edge (not when the table's own width changes).
    func tableViewColumnDidResize(_ notification: Notification) {
        guard let table, let header = table.headerView, header.resizedColumn >= 0 else { return }
        let encoded = table.tableColumns
            .map { "\($0.identifier.rawValue):\(Int($0.width.rounded()))" }
            .joined(separator: ",")
        Preferences.defaults.set(encoded, forKey: PrefKey.graphColumnWidths.rawValue)
    }
}
