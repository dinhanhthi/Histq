// Pane A or B of the conflict editor: that side's whole file in an NSTableView with fixed 18 pt rows that never wrap.
// Lines inside a conflict are tinted (A blue, B gold; stronger once ticked) and get a checkbox in the gutter; the
// first line of each conflict also gets the hunk's checkbox (all of that side's lines of the conflict). ⌘C copies the
// selected lines whole.
import AppKit
import HistqCore
import SwiftUI

/// Sizes shared by the three panes: one line height everywhere, so a scroll offset maps to a line in each pane.
enum ConflictLayout {
    static let lineHeight: CGFloat = DiffLayout.lineHeight
    /// The hunk checkbox's column, then the line checkbox's.
    static let checkboxWidth: CGFloat = 20
    static let barWidth: CGFloat = 3
}

/// One side's lines and checkboxes. `revision` changes with every tick or edit (the rows redraw); `loadID` with every
/// load (the rows reload).
struct ConflictLinePane: NSViewRepresentable {
    let side: ThreeWayMerge.Side
    /// The side's lines without their line breaks.
    let lines: [String]
    let merge: ThreeWayMerge
    let revision: Int
    let loadID: Int
    let sync: ScrollSync
    var onTickLines: @MainActor (Bool, [Int]) -> Void = { _, _ in }
    var onTickConflict: @MainActor (Bool, Int) -> Void = { _, _ in }

    func makeCoordinator() -> ConflictPaneController { ConflictPaneController() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ConflictTableView()
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.rowHeight = ConflictLayout.lineHeight
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
        sync.register(scroll, as: side == .a ? .a : .b)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }
}

/// The pane's table: its one column is as wide as the longest line or the card, whichever is wider.
final class ConflictTableView: NSTableView {
    var contentWidth: CGFloat = 0 {
        didSet { if contentWidth != oldValue { tile() } }
    }
    weak var controller: ConflictPaneController?

    override func tile() {
        super.tile()
        guard let clip = enclosingScrollView?.contentView, let column = tableColumns.first else { return }
        let width = max(contentWidth, clip.bounds.width)
        if abs(column.width - width) > 0.5 { column.width = width }
    }

    @objc func copy(_ sender: Any?) {
        controller?.copySelection()
    }
}

/// What a row shows about the conflicts: nothing outside them; inside one, its index and the checkbox states.
struct ConflictLineState: Equatable {
    /// The conflict (0-based) the line belongs to, nil outside any.
    var conflict: Int?
    var isTicked = false
    /// The first line of its conflict on this side: it carries the hunk checkbox.
    var isFirst = false
    /// The hunk checkbox: every line of the conflict on this side ticked, or some of them.
    var hunk: NSControl.StateValue = .off
}

/// The table's data source and delegate. Reloads for a new load; a tick only reconfigures the rows on screen.
@MainActor
final class ConflictPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var table: ConflictTableView?
    private var view: ConflictLinePane?
    private var shown: (loadID: Int, revision: Int)?
    /// The conflict index of each region that is a conflict.
    private var conflictOfRegion: [Int: Int] = [:]
    private var numberWidth: CGFloat = 40

    private static let cellID = NSUserInterfaceItemIdentifier("conflictLine")
    private static let rowID = NSUserInterfaceItemIdentifier("conflictRow")

    func attach(_ table: ConflictTableView) {
        self.table = table
        table.controller = self
        table.dataSource = self
        table.delegate = self
    }

    func update(_ view: ConflictLinePane) {
        self.view = view
        guard let table else { return }
        if shown?.loadID != view.loadID {
            shown = (view.loadID, view.revision)
            conflictOfRegion = Dictionary(
                uniqueKeysWithValues: view.merge.conflictRegions.enumerated().map { ($0.element, $0.offset) })
            let digits = max(3, String(view.lines.count).count)
            numberWidth = CGFloat(digits) * DiffLayout.charWidth + 12
            let longest = view.lines.reduce(0) { longest, line in
                max(longest, line.utf16.count + line.utf16.count { $0 == 0x09 } * (DiffLayout.tabWidth - 1))
            }
            table.reloadData()
            table.contentWidth = textX + CGFloat(longest) * DiffLayout.charWidth + 24
        } else if shown?.revision != view.revision {
            shown = (view.loadID, view.revision)
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                             columnIndexes: IndexSet(integer: 0))
        }
    }

    private var textX: CGFloat { 2 * ConflictLayout.checkboxWidth + 4 + numberWidth + 10 }

    /// Where `row` sits among the conflicts of this side, with its checkbox states.
    private func state(of row: Int) -> ConflictLineState {
        guard let view else { return ConflictLineState() }
        let merge = view.merge
        let pane: ThreeWayMerge.Pane = view.side == .a ? .a : .b
        guard let index = merge.region(containing: row, in: pane), let k = conflictOfRegion[index] else {
            return ConflictLineState()
        }
        let lines = view.side == .a ? merge.regions[index].a : merge.regions[index].b
        guard lines.contains(row) else { return ConflictLineState() }
        let ticked = lines.count { merge.isTicked(view.side, line: $0) }
        return ConflictLineState(
            conflict: k, isTicked: merge.isTicked(view.side, line: row), isFirst: row == lines.lowerBound,
            hunk: ticked == 0 ? .off : ticked == lines.count ? .on : .mixed)
    }

    // MARK: Data

    func numberOfRows(in tableView: NSTableView) -> Int { view?.lines.count ?? 0 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: Self.rowID, owner: nil) as? DiffRowView ?? {
            let view = DiffRowView()
            view.identifier = Self.rowID
            return view
        }()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let view, view.lines.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? ConflictLineCellView ?? {
            let cell = ConflictLineCellView()
            cell.identifier = Self.cellID
            return cell
        }()
        let state = state(of: row)
        cell.configure(
            number: row + 1, text: view.lines[row], side: view.side, state: state, numberWidth: numberWidth,
            textX: textX
        ) { [weak self] isHunk in
            self?.toggle(row: row, hunk: isHunk)
        }
        return cell
    }

    /// A checkbox click: the line's tick flips; the hunk's ticks every line of its side, or unticks them when all
    /// were ticked.
    private func toggle(row: Int, hunk: Bool) {
        guard let view else { return }
        let state = state(of: row)
        guard let k = state.conflict else { return }
        if hunk {
            view.onTickConflict(state.hunk != .on, k)
        } else {
            view.onTickLines(!state.isTicked, [row])
        }
    }

    /// The selected lines, whole, one per line.
    func copySelection() {
        guard let table, let view else { return }
        let lines = table.selectedRowIndexes.compactMap { view.lines.indices.contains($0) ? view.lines[$0] : nil }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n") + "\n", forType: .string)
    }
}

/// A line of pane A or B: its band and edge bar inside a conflict, the hunk and line checkboxes, the number, the text.
final class ConflictLineCellView: NSView {
    private let hunkBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let lineBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var number = 0
    private var text = ""
    private var side: ThreeWayMerge.Side = .a
    private var state = ConflictLineState()
    private var numberWidth: CGFloat = 40
    private var textX: CGFloat = 80
    private var onToggle: ((Bool) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (box, isHunk) in [(hunkBox, true), (lineBox, false)] {
            box.controlSize = .small
            box.target = self
            box.action = isHunk ? #selector(hunkPressed) : #selector(linePressed)
            box.allowsMixedState = isHunk
            box.setAccessibilityLabel(isHunk ? "Take this conflict's lines" : "Take this line")
            addSubview(box)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(number: Int, text: String, side: ThreeWayMerge.Side, state: ConflictLineState, numberWidth: CGFloat,
                   textX: CGFloat, onToggle: @escaping (Bool) -> Void)
    {
        self.number = number
        self.text = text
        self.side = side
        self.state = state
        self.numberWidth = numberWidth
        self.textX = textX
        self.onToggle = onToggle
        let inConflict = state.conflict != nil
        lineBox.isHidden = !inConflict
        lineBox.state = state.isTicked ? .on : .off
        hunkBox.isHidden = !(inConflict && state.isFirst)
        hunkBox.state = state.hunk
        setAccessibilityLabel("\(number): \(text)")
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let size = hunkBox.intrinsicContentSize
        let y = (bounds.height - size.height) / 2
        hunkBox.frame = NSRect(x: ConflictLayout.barWidth + 3, y: y, width: size.width, height: size.height)
        lineBox.frame = NSRect(x: ConflictLayout.barWidth + 3 + ConflictLayout.checkboxWidth, y: y, width: size.width,
                               height: size.height)
    }

    @objc private func hunkPressed() { onToggle?(true) }
    @objc private func linePressed() { onToggle?(false) }

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
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height
        if state.conflict != nil {
            let isA = side == .a
            let fill = state.isTicked
                ? (isA ? Palette.conflictATickedFill : Palette.conflictBTickedFill)
                : (isA ? Palette.conflictAFill : Palette.conflictBFill)
            fill.setFill()
            bounds.fill(using: .sourceOver)
            (isA ? Palette.conflictA : Palette.conflictB).setFill()
            NSRect(x: 0, y: 0, width: ConflictLayout.barWidth, height: height).fill()
        }
        let numberX = 2 * ConflictLayout.checkboxWidth + 4
        let numberY = (height - DiffLayout.numberFont.boundingRectForFont.height) / 2
        NSString(string: "\(number)").draw(
            in: NSRect(x: numberX, y: numberY, width: numberWidth - 6, height: height), withAttributes: Style.number)
        let textY = (height - (DiffLayout.font.ascender - DiffLayout.font.descender)) / 2
        NSAttributedString(string: text, attributes: Style.text).draw(at: NSPoint(x: textX, y: textY))
    }
}
