// The lines of one side of a file's diff: an NSTableView with fixed-height rows that never wrap. Each line row has the
// old and new line numbers, a `+`/`−` gutter, a green or red band, a stronger mark on the changed part of a replaced
// line, and syntax colors; each hunk starts with a header row whose buttons stage, unstage or discard the hunk, or only
// its selected lines. ⌘C copies the selected lines whole; Esc goes back to the graph.
//
// The rows (with their tokens) are built off the main actor when the diff loads: the table only draws the rows on
// screen, so its cost does not grow with the file.
import AppKit
import HistqCore
import SwiftUI

/// Which changes a diff section holds, and what its hunk buttons can do with them.
enum DiffSide: Hashable, Sendable {
    /// The working tree against the index.
    case unstaged
    /// The index against HEAD.
    case staged
    /// A commit or a stash against its first parent: read-only.
    case commit
    /// A file git does not track: its lines, read-only (the WIP panel stages it whole).
    case untracked

    var title: String {
        switch self {
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        case .commit: "Changes"
        case .untracked: "Untracked"
        }
    }

    var systemImage: String {
        switch self {
        case .unstaged: "doc.badge.ellipsis"
        case .staged: "tray.full"
        case .commit: "doc.text"
        case .untracked: "questionmark.square.dashed"
        }
    }

    /// The hunk header buttons, in their order.
    var actions: [PatchBuilder.Action] {
        switch self {
        case .unstaged: [.stage, .discard]
        case .staged: [.unstage]
        case .commit, .untracked: []
        }
    }
}

/// One row of a diff table: a hunk header or a line, with its tokens and its intraline mark ready to draw.
struct DiffRow: Sendable {
    enum Kind: Sendable, Equatable {
        /// The header of hunk `index`.
        case hunk(Int)
        case context
        case added
        case removed
    }

    let kind: Kind
    /// The line in its `FileDiff` (what a patch selects); nil for a hunk header, an untracked file's line and a
    /// combined diff's line (read-only).
    let id: DiffLineID?
    let oldLine: Int?
    let newLine: Int?
    /// The line without its line break (a CR before it is dropped too), or the hunk header's text.
    let text: String
    let tokens: [SyntaxToken]
    /// The changed part of a replaced line (UTF-16 range of `text`), when a removed line and an added line pair up.
    var emphasis: NSRange?

    var isLine: Bool {
        if case .hunk = kind { false } else { true }
    }
}

/// One card of a file's diff: the changes of one side, as rows for both modes.
struct DiffSection: Sendable, Identifiable {
    let side: DiffSide
    /// git's diff with its usual context (Diff mode); nil for an untracked file.
    let diff: FileDiff?
    /// The same diff with the whole file as context (Full file mode); nil when git gave none.
    let full: FileDiff?
    let rows: [DiffRow]
    let fullRows: [DiffRow]
    let additions: Int
    let deletions: Int

    var id: DiffSide { side }
    var isBinary: Bool { diff?.isBinary == true }

    func rows(_ mode: DiffMode) -> [DiffRow] { mode == .full ? fullRows : rows }

    /// The diff whose line ids the rows of `mode` carry: the one a patch is built from.
    func file(_ mode: DiffMode) -> FileDiff? { mode == .full ? full ?? diff : diff }

    /// Nil when git printed no diff for this side. Tokens come from scanning the full-context diff from the file's
    /// first line, one scan state per side, so a hunk that starts inside a block comment is colored right.
    nonisolated init?(side: DiffSide, diff: FileDiff?, full: FileDiff?, language: Language?) {
        guard let diff else { return nil }
        self.side = side
        self.diff = diff
        self.full = full
        let tokens = DiffRowBuilder.tokens(full ?? diff, language: language)
        rows = DiffRowBuilder.rows(diff, tokens: tokens)
        fullRows = full.map { DiffRowBuilder.rows($0, tokens: tokens) } ?? rows
        additions = diff.additions
        deletions = diff.deletions
    }

    /// An untracked file's text as added lines, numbered from 1.
    nonisolated init(untracked data: Data, language: Language?) {
        side = .untracked
        diff = nil
        full = nil
        var state = ScanState()
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        rows = lines.enumerated().map { index, bytes in
            let text = DiffRowBuilder.display(String(decoding: bytes, as: UTF8.self))
            let tokens = SyntaxScanner.scan(line: text, state: &state, language: language)
            return DiffRow(kind: .added, id: nil, oldLine: nil, newLine: index + 1, text: text, tokens: tokens)
        }
        fullRows = rows
        additions = rows.count
        deletions = 0
    }
}

/// Builds the rows of a diff, off the main actor.
enum DiffRowBuilder {
    /// Each side's tokens by line number.
    struct SideTokens: Sendable {
        var old: [Int: [SyntaxToken]] = [:]
        var new: [Int: [SyntaxToken]] = [:]
    }

    /// Scans `source`'s lines in order, the old side's lines (context and removed) with one state and the new side's
    /// (context and added) with another. With the full-context diff that is every line of both files.
    nonisolated static func tokens(_ source: FileDiff, language: Language?) -> SideTokens {
        guard let language else { return SideTokens() }
        var tokens = SideTokens()
        var oldState = ScanState()
        var newState = ScanState()
        for hunk in source.hunks {
            for line in hunk.lines {
                let text = display(line.text)
                if line.kind != .added, let number = line.oldLine {
                    tokens.old[number] = SyntaxScanner.scan(line: text, state: &oldState, language: language)
                }
                if line.kind != .removed, let number = line.newLine {
                    tokens.new[number] = SyntaxScanner.scan(line: text, state: &newState, language: language)
                }
            }
        }
        return tokens
    }

    /// A header row per hunk, then its lines. A combined diff's lines get no id: PatchBuilder refuses them.
    nonisolated static func rows(_ file: FileDiff, tokens: SideTokens) -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(file.hunks.reduce(file.hunks.count) { $0 + $1.lines.count })
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            let header = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
            rows.append(DiffRow(
                kind: .hunk(hunkIndex), id: nil, oldLine: nil, newLine: nil,
                text: hunk.section.isEmpty ? header : header + " " + hunk.section, tokens: []))
            let first = rows.count
            for (lineIndex, line) in hunk.lines.enumerated() {
                let kind: DiffRow.Kind = switch line.kind {
                case .context: .context
                case .added: .added
                case .removed: .removed
                }
                let lineTokens = line.kind == .removed
                    ? line.oldLine.flatMap { tokens.old[$0] } : line.newLine.flatMap { tokens.new[$0] }
                rows.append(DiffRow(
                    kind: kind, id: file.isCombined ? nil : DiffLineID(hunk: hunkIndex, line: lineIndex),
                    oldLine: line.oldLine, newLine: line.newLine, text: display(line.text), tokens: lineTokens ?? []))
            }
            markChanges(&rows, from: first)
        }
        return rows
    }

    /// The text to show: without the CR of a CRLF line.
    nonisolated static func display(_ text: String) -> String {
        text.hasSuffix("\r") ? String(text.dropLast()) : text
    }

    /// Pairs each block of removed lines with the block of added lines right after it when both have as many lines,
    /// and marks what changed in each pair (between the common start and the common end).
    private nonisolated static func markChanges(_ rows: inout [DiffRow], from start: Int) {
        var index = start
        while index < rows.count {
            guard rows[index].kind == .removed else {
                index += 1
                continue
            }
            var removedEnd = index
            while removedEnd < rows.count, rows[removedEnd].kind == .removed { removedEnd += 1 }
            var addedEnd = removedEnd
            while addedEnd < rows.count, rows[addedEnd].kind == .added { addedEnd += 1 }
            if removedEnd - index == addedEnd - removedEnd {
                for offset in 0..<(removedEnd - index) {
                    let (old, new) = changedRanges(rows[index + offset].text, rows[removedEnd + offset].text)
                    rows[index + offset].emphasis = old
                    rows[removedEnd + offset].emphasis = new
                }
            }
            index = addedEnd
        }
    }

    /// The parts of `old` and `new` between their common prefix and suffix; nil when nothing is common (the whole line
    /// changed: the band says it already) or when a line is too long to be worth it.
    private nonisolated static func changedRanges(_ old: String, _ new: String) -> (NSRange?, NSRange?) {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        guard a.count < 2000, b.count < 2000 else { return (nil, nil) }
        let shorter = min(a.count, b.count)
        var prefix = 0
        while prefix < shorter, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        guard prefix + suffix > 0 else { return (nil, nil) }
        let oldLength = a.count - prefix - suffix
        let newLength = b.count - prefix - suffix
        return (oldLength > 0 ? NSRange(location: prefix, length: oldLength) : nil,
                newLength > 0 ? NSRange(location: prefix, length: newLength) : nil)
    }
}

// MARK: - Table

/// One diff section's table. `loadID` and `mode` say which rows it shows: a new load (after a stage) or another mode
/// reloads them; any other update only refreshes the hunk buttons. `onApply` gets the action, the lines (the selected
/// changed lines of a hunk, or the whole hunk) and the diff they belong to.
struct DiffLineTable: NSViewRepresentable {
    let section: DiffSection
    let mode: DiffMode
    let loadID: Int
    var onApply: @MainActor (PatchBuilder.Action, Set<DiffLineID>, FileDiff) -> Void = { _, _, _ in }
    var onClose: @MainActor () -> Void = {}

    func makeCoordinator() -> DiffTableController { DiffTableController() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = DiffTableView()
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.focusRingType = .none
        table.headerView = nil
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = []
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        // Lines never wrap: a long line scrolls sideways.
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        context.coordinator.attach(table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }
}

/// Fonts and column positions of a table's rows. The gutters fit the largest line number; the content width fits the
/// longest line, so the table scrolls sideways instead of wrapping.
struct DiffLayout {
    @MainActor static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    @MainActor static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    @MainActor static let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
    static let lineHeight: CGFloat = 18
    static let hunkHeight: CGFloat = 28
    /// Spaces per tab.
    static let tabWidth = 4
    static let signWidth: CGFloat = 16

    let numberWidth: CGFloat
    let contentWidth: CGFloat

    var newNumberX: CGFloat { numberWidth }
    var signX: CGFloat { 2 * numberWidth }
    var textX: CGFloat { signX + Self.signWidth }

    @MainActor init(rows: [DiffRow]) {
        var largest = 0
        var longest = 0
        for row in rows where row.isLine {
            largest = max(largest, row.oldLine ?? 0, row.newLine ?? 0)
            let tabs = row.text.utf16.count { $0 == 0x09 }
            longest = max(longest, row.text.utf16.count + tabs * (Self.tabWidth - 1))
        }
        let digits = max(3, String(largest).count)
        numberWidth = CGFloat(digits) * Self.charWidth + 14
        contentWidth = 2 * numberWidth + Self.signWidth + CGFloat(longest) * Self.charWidth + 24
    }

    init() {
        numberWidth = 40
        contentWidth = 0
    }
}

/// The diff table: its one column is as wide as the longest line or the card, whichever is wider. Esc asks to go back,
/// ⌘C copies the selected lines, a right-click opens the selection's menu.
final class DiffTableView: NSTableView {
    var contentWidth: CGFloat = 0 {
        didSet { if contentWidth != oldValue { tile() } }
    }
    weak var controller: DiffTableController?
    /// Takes the keyboard once, when it first shows, so ⌘C and Esc work without a click.
    private var tookFocus = false

    override func tile() {
        super.tile()
        guard let clip = enclosingScrollView?.contentView, let column = tableColumns.first else { return }
        let width = max(contentWidth, clip.bounds.width)
        if abs(column.width - width) > 0.5 { column.width = width }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !tookFocus else { return }
        tookFocus = true
        // The other tables of the same diff do not steal it.
        if !(window.firstResponder is DiffTableView) { window.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        // Escape: back to the graph.
        if event.keyCode == 53 {
            controller?.close()
        } else {
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        controller?.copySelection()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.menu(at: row(at: convert(event.locationInWindow, from: nil)))
    }
}

/// The table's data source and delegate: it keeps the rows it shows and reloads only for a new load or mode.
@MainActor
final class DiffTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var table: DiffTableView?
    private var view: DiffLineTable?
    private var rows: [DiffRow] = []
    private var layout = DiffLayout()

    private struct Shown: Equatable {
        let loadID: Int
        let mode: DiffMode
        let side: DiffSide
    }

    private var shown: Shown?

    private static let lineID = NSUserInterfaceItemIdentifier("diffLine")
    private static let hunkID = NSUserInterfaceItemIdentifier("diffHunk")
    private static let rowID = NSUserInterfaceItemIdentifier("diffRow")

    func attach(_ table: DiffTableView) {
        self.table = table
        table.controller = self
        table.dataSource = self
        table.delegate = self
    }

    func update(_ view: DiffLineTable) {
        self.view = view
        guard let table else { return }
        let key = Shown(loadID: view.loadID, mode: view.mode, side: view.section.side)
        guard key != shown else { return }
        let modeChanged = shown.map { $0.mode != key.mode } ?? false
        shown = key
        rows = view.section.rows(view.mode)
        layout = DiffLayout(rows: rows)
        // A reload after a stage keeps the scroll offset; the selection goes (its lines may be gone).
        // `reloadData` keeps the selected row indexes, which would now point at other lines, so clear them.
        table.reloadData()
        table.deselectAll(nil)
        table.contentWidth = layout.contentWidth
        if modeChanged { scrollToFirstChange(table) }
        #if DEBUG
        runLaunchStage()
        #endif
    }

    /// In Full file mode the first change is the interesting part: it goes near the top.
    private func scrollToFirstChange(_ table: NSTableView) {
        guard let clip = table.enclosingScrollView?.contentView else { return }
        let first = rows.firstIndex { $0.kind == .added || $0.kind == .removed } ?? 0
        let y = first < rows.count ? max(0, table.rect(ofRow: first).minY - 3 * DiffLayout.lineHeight) : 0
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin)
        table.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    func close() {
        view?.onClose()
    }

    // MARK: Data

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) && !rows[row].isLine ? DiffLayout.hunkHeight : DiffLayout.lineHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: Self.rowID, owner: nil) as? DiffRowView ?? {
            let view = DiffRowView()
            view.identifier = Self.rowID
            return view
        }()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let data = rows[row]
        if case .hunk(let hunk) = data.kind {
            let cell = tableView.makeView(withIdentifier: Self.hunkID, owner: nil) as? DiffHunkCellView ?? {
                let cell = DiffHunkCellView()
                cell.identifier = Self.hunkID
                return cell
            }()
            cell.configure(text: data.text, buttons: buttons(forHunk: hunk)) { [weak self] action in
                self?.apply(action, hunk: hunk)
            }
            return cell
        }
        let cell = tableView.makeView(withIdentifier: Self.lineID, owner: nil) as? DiffLineCellView ?? {
            let cell = DiffLineCellView()
            cell.identifier = Self.lineID
            return cell
        }()
        cell.row = data
        cell.layout = layout
        cell.needsDisplay = true
        return cell
    }

    /// Hunk headers are not lines: a click or a drag never selects them.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.filteredIndexSet { rows.indices.contains($0) && rows[$0].isLine }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshHunkButtons()
    }

    // MARK: Actions

    /// The changed lines selected in `hunk`.
    private func selectedLines(inHunk hunk: Int) -> Set<DiffLineID> {
        guard let table else { return [] }
        var lines = Set<DiffLineID>()
        for index in table.selectedRowIndexes where rows.indices.contains(index) {
            let row = rows[index]
            if let id = row.id, id.hunk == hunk, row.kind == .added || row.kind == .removed { lines.insert(id) }
        }
        return lines
    }

    /// The header's buttons: "Stage Hunk", or "Stage 2 Lines" while lines of that hunk are selected. None for a
    /// read-only diff (a commit, a merge's combined diff, an untracked file).
    private func buttons(forHunk hunk: Int) -> [(PatchBuilder.Action, String)] {
        guard let view, let file = view.section.file(view.mode), !file.isCombined else { return [] }
        let count = selectedLines(inHunk: hunk).count
        let what = count == 0 ? "Hunk" : count == 1 ? "1 Line" : "\(count) Lines"
        return view.section.side.actions.map { action in
            let verb = switch action {
            case .stage: "Stage"
            case .unstage: "Unstage"
            case .discard: "Discard"
            }
            return (action, "\(verb) \(what)")
        }
    }

    private func refreshHunkButtons() {
        guard let table else { return }
        let visible = table.rows(in: table.visibleRect)
        for index in visible.location..<NSMaxRange(visible) where rows.indices.contains(index) {
            guard case .hunk(let hunk) = rows[index].kind,
                  let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? DiffHunkCellView
            else { continue }
            cell.configure(text: rows[index].text, buttons: buttons(forHunk: hunk)) { [weak self] action in
                self?.apply(action, hunk: hunk)
            }
        }
    }

    /// A hunk button: the hunk's selected changed lines, or the whole hunk when none is selected.
    private func apply(_ action: PatchBuilder.Action, hunk: Int) {
        guard let view, let file = view.section.file(view.mode), file.hunks.indices.contains(hunk) else { return }
        let selected = selectedLines(inHunk: hunk)
        view.onApply(action, selected.isEmpty ? Set(file.changedLineIDs(inHunk: hunk)) : selected, file)
    }

    /// The selected changed lines of every hunk.
    private func selectedChangedLines() -> Set<DiffLineID> {
        guard let table else { return [] }
        return Set(table.selectedRowIndexes.compactMap { index in
            rows.indices.contains(index) && (rows[index].kind == .added || rows[index].kind == .removed)
                ? rows[index].id : nil
        })
    }

    /// The selected lines, whole, one per line (no `+`/`−`, no line numbers).
    func copySelection() {
        guard let table else { return }
        let lines = table.selectedRowIndexes.compactMap { rows.indices.contains($0) && rows[$0].isLine ? rows[$0].text : nil }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n") + "\n", forType: .string)
    }

    /// A right-click on a line: it joins the selection (or replaces it when it was not selected), then Copy and the
    /// side's actions on the selected lines.
    func menu(at row: Int) -> NSMenu? {
        guard let table, let view, rows.indices.contains(row), rows[row].isLine else { return nil }
        if !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        var entries: [MenuEntry] = [.action("Copy") { [weak self] in self?.copySelection() }]
        let lines = selectedChangedLines()
        if let file = view.section.file(view.mode), !file.isCombined, !lines.isEmpty {
            let what = lines.count == 1 ? "1 Line" : "\(lines.count) Lines"
            entries.append(.separator)
            for action in view.section.side.actions {
                switch action {
                case .stage: entries.append(.action("Stage \(what)") { view.onApply(.stage, lines, file) })
                case .unstage: entries.append(.action("Unstage \(what)") { view.onApply(.unstage, lines, file) })
                case .discard:
                    entries.append(.action("Discard \(what)…", destructive: true) { view.onApply(.discard, lines, file) })
                }
            }
        }
        return MenuBuilder.menu(entries)
    }

    #if DEBUG
    /// Whether `-HistqStageLines` already ran in this launch.
    private static var launchStageDone = false

    /// DEBUG `-HistqStageLines <n>,<m>`: once, in the first table that can stage, selects the changed lines with those
    /// line numbers (new numbers for added lines, old for removed) and presses their hunk's Stage button, the path a
    /// user's selection and click take.
    private func runLaunchStage() {
        guard !Self.launchStageDone, let table, let view, view.section.side.actions.contains(.stage),
              let spec = AppState.launchFlag("-HistqStageLines")
        else { return }
        Self.launchStageDone = true
        let wanted = Set(spec.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        let indexes = IndexSet(rows.indices.filter { index in
            switch rows[index].kind {
            case .added: wanted.contains(rows[index].newLine ?? -1)
            case .removed: wanted.contains(rows[index].oldLine ?? -1)
            case .context, .hunk: false
            }
        })
        guard let first = indexes.first, let hunk = rows[first].id?.hunk else { return }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        apply(.stage, hunk: hunk)
    }
    #endif
}

// MARK: - Rows

/// A selected line: the graph's neutral fill and edge, under the line's own band.
final class DiffRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 0)
        Palette.graphSelection.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        Palette.graphSelectionBorder.setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
        edge.lineWidth = 1
        edge.stroke()
    }
}

/// A line: its band, the old and new numbers, the sign, the changed part's mark, then the text in syntax colors.
final class DiffLineCellView: NSView {
    var row: DiffRow? {
        didSet { setAccessibilityLabel(row?.text) }
    }
    var layout = DiffLayout()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @MainActor
    private enum Style {
        static let paragraph: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.tabStops = []
            style.defaultTabInterval = CGFloat(DiffLayout.tabWidth) * DiffLayout.charWidth
            style.lineBreakMode = .byClipping
            return style
        }()
        static let text: [NSAttributedString.Key: Any] = [
            .font: DiffLayout.font, .foregroundColor: Palette.diffText, .paragraphStyle: paragraph,
        ]
        static let number: [NSAttributedString.Key: Any] = {
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            return [.font: DiffLayout.numberFont, .foregroundColor: Palette.diffLineNumber, .paragraphStyle: style]
        }()
        static let addedSign: [NSAttributedString.Key: Any] = [
            .font: DiffLayout.font, .foregroundColor: Palette.diffAddedSign,
        ]
        static let removedSign: [NSAttributedString.Key: Any] = [
            .font: DiffLayout.font, .foregroundColor: Palette.diffRemovedSign,
        ]

        static func color(_ kind: TokenKind) -> NSColor {
            switch kind {
            case .keyword: Palette.syntaxKeyword
            case .string: Palette.syntaxString
            case .number: Palette.syntaxNumber
            case .comment: Palette.syntaxComment
            case .type: Palette.syntaxType
            case .punctuation: Palette.syntaxPunctuation
            case .plain: Palette.diffText
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let height = bounds.height
        switch row.kind {
        case .added:
            Palette.diffAddedFill.setFill()
            bounds.fill(using: .sourceOver)
        case .removed:
            Palette.diffRemovedFill.setFill()
            bounds.fill(using: .sourceOver)
        case .context, .hunk:
            break
        }
        let numberY = (height - DiffLayout.numberFont.boundingRectForFont.height) / 2
        if let old = row.oldLine {
            NSString(string: "\(old)").draw(
                in: NSRect(x: 0, y: numberY, width: layout.numberWidth - 8, height: height), withAttributes: Style.number)
        }
        if let new = row.newLine {
            NSString(string: "\(new)").draw(
                in: NSRect(x: layout.newNumberX, y: numberY, width: layout.numberWidth - 8, height: height),
                withAttributes: Style.number)
        }
        let textY = (height - (DiffLayout.font.ascender - DiffLayout.font.descender)) / 2
        switch row.kind {
        case .added: NSString(string: "+").draw(at: NSPoint(x: layout.signX + 4, y: textY), withAttributes: Style.addedSign)
        case .removed: NSString(string: "−").draw(at: NSPoint(x: layout.signX + 4, y: textY), withAttributes: Style.removedSign)
        case .context, .hunk: break
        }

        let text = NSMutableAttributedString(string: row.text, attributes: Style.text)
        let length = text.length
        for token in row.tokens where NSMaxRange(token.range) <= length {
            text.addAttribute(.foregroundColor, value: Style.color(token.kind), range: token.range)
        }
        if let emphasis = row.emphasis, NSMaxRange(emphasis) <= length {
            // Measured on the text itself, so tabs before the mark are counted as drawn.
            let start = text.attributedSubstring(from: NSRange(location: 0, length: emphasis.location)).size().width
            let width = text.attributedSubstring(from: emphasis).size().width
            (row.kind == .added ? Palette.diffAddedEmphasis : Palette.diffRemovedEmphasis).setFill()
            NSBezierPath(roundedRect: NSRect(x: layout.textX + start, y: 1, width: width, height: height - 2),
                         xRadius: 2, yRadius: 2).fill()
        }
        text.draw(at: NSPoint(x: layout.textX, y: textY))
    }
}

/// A hunk's header: its `@@` range and section, then its buttons at the trailing edge.
final class DiffHunkCellView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var onAction: ((PatchBuilder.Action) -> Void)?
    private var actions: [PatchBuilder.Action] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = DiffLayout.numberFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.orientation = .horizontal
        stack.spacing = 6
        for view in [label, stack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // The buttons stay in the card's visible width even when a long line widens the table.
        trailingConstraint = stack.trailingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        trailingConstraint?.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var trailingConstraint: NSLayoutConstraint?

    override func layout() {
        let visible = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        trailingConstraint?.constant = min(bounds.width, visible) - 8
        super.layout()
    }

    func configure(text: String, buttons: [(PatchBuilder.Action, String)],
                   onAction: @escaping (PatchBuilder.Action) -> Void)
    {
        label.stringValue = text
        self.onAction = onAction
        actions = buttons.map(\.0)
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, (action, title)) in buttons.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(pressed(_:)))
            button.bezelStyle = .push
            // Every button of the app is a capsule (user, 2026-11-13); before macOS 26 AppKit has no shape to pick.
            if #available(macOS 26, *) { button.borderShape = .capsule }
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            button.tag = index
            button.hasDestructiveAction = action == .discard
            stack.addArrangedSubview(button)
        }
        needsLayout = true
    }

    @objc private func pressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        onAction?(actions[sender.tag])
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.diffHunkFill.setFill()
        bounds.fill(using: .sourceOver)
    }
}
