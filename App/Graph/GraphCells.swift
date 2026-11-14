// The graph table's cells other than the lanes: the ref badges (joined to their node by a line in the lane color; a
// branch with an open pull request carries its "#N" chip, which a click opens), the text columns, the selected row's
// neutral capsule and the column header. Every cell draws itself in `draw(_:)` with cached fonts, attributes and
// symbols; text is truncated with "…".
import AppKit
import HistqCore

// MARK: - Ref badges

/// One label in the BRANCH / TAG column.
struct RefBadge: Hashable {
    enum Kind: Hashable {
        /// A local branch (laptop icon), with the cloud icon when its upstream points at the same commit. `isHead`
        /// adds a check in front.
        case branch(isLocal: Bool, isRemote: Bool, isHead: Bool)
        case tag
        /// A detached HEAD.
        case head
        /// Another worktree's WIP row: the worktree's folder name.
        case worktree
    }

    /// An open pull request whose head is this branch: drawn as a chip at the badge's end.
    struct PullRequest: Hashable, Sendable {
        let number: Int
        let isDraft: Bool
    }

    let kind: Kind
    let name: String
    /// Commits ahead of / behind the upstream (local branches).
    var ahead = 0
    var behind = 0
    var pullRequest: PullRequest?

    /// The badges of every labeled commit, in row order: HEAD's branch (or a detached HEAD) first, then local
    /// branches, remote branches that are not merged into a local badge, then tags. Built once per refs read (and per
    /// change of `pullRequests`, the store's `branchPullRequests`: a remote branch's pull request by its name, which a
    /// local branch gets through its upstream).
    static func badges(for refs: Refs, pullRequests: [String: PullRequest] = [:]) -> [String: [RefBadge]] {
        var byCommit: [String: [RefBadge]] = [:]
        let remoteCommits = Dictionary(refs.remoteBranches.map { ($0.name, $0.commit) }, uniquingKeysWith: { a, _ in a })
        var mergedRemotes = Set<String>()
        if case .detached(let commit) = refs.head {
            byCommit[commit, default: []].append(RefBadge(kind: .head, name: "HEAD"))
        }
        for branch in refs.localBranches.sorted(by: { $0.isHead && !$1.isHead }) {
            var isRemote = false
            if let upstream = branch.upstream, remoteCommits[upstream] == branch.commit {
                isRemote = true
                mergedRemotes.insert(upstream)
            }
            byCommit[branch.commit, default: []].append(RefBadge(
                kind: .branch(isLocal: true, isRemote: isRemote, isHead: branch.isHead), name: branch.name,
                ahead: branch.ahead, behind: branch.behind, pullRequest: branch.upstream.flatMap { pullRequests[$0] }))
        }
        for remote in refs.remoteBranches where !mergedRemotes.contains(remote.name) {
            byCommit[remote.commit, default: []].append(RefBadge(
                kind: .branch(isLocal: false, isRemote: true, isHead: false), name: remote.name,
                pullRequest: pullRequests[remote.name]))
        }
        for tag in refs.tags {
            byCommit[tag.commit ?? tag.target, default: []].append(RefBadge(kind: .tag, name: tag.name))
        }
        return byCommit
    }
}

/// The BRANCH / TAG column's cell: the row's badges from the left, as many as fit, then "+N" for the rest; the first
/// badge's name is truncated with "…" when even it does not fit. A line in the lane color runs from the last badge to
/// the column's right edge, where the graph cell continues it to the node.
final class RefBadgeCellView: NSView {
    var badges: [RefBadge] = []
    /// The row's lane color (`GraphRow.color`).
    var color = 0
    var metrics = GraphMetrics(density: "regular")

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    @MainActor
    private enum Style {
        // Normal weight, a size up from the message text (user, 2026-11-13, as GitKraken's labels).
        static let font = NSFont.systemFont(ofSize: 13)
        static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        static let paragraph: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            return style
        }()
        static let text: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: Palette.graphBadgeText, .paragraphStyle: paragraph,
        ]
        static let count: [NSAttributedString.Key: Any] = [
            .font: countFont, .foregroundColor: Palette.graphBadgeText,
        ]
        static let leading: CGFloat = 6
        static let padding: CGFloat = 7
        static let gap: CGFloat = 4
        static let iconGap: CGFloat = 3
        /// The check's slot. The laptop, cloud and tag get `refIcon`: bigger, so they read at a glance (user,
        /// 2026-11-13); the text and the badge height stay.
        static let icon: CGFloat = 12
        static let refIcon: CGFloat = 15
        static let radius: CGFloat = 5
        /// A badge's height, less in a row too short for it (compact).
        static let height: CGFloat = 22
        /// Room kept for the line to the node.
        static let trailing: CGFloat = 8
        /// The pull request chip: inset from the badge's edges, its own padding, and its corner radius.
        static let chipInset: CGFloat = 2
        static let chipPadding: CGFloat = 5
        static let chipRadius: CGFloat = 4
    }

    /// A glyph's slot width: the check keeps the small one.
    private static func iconWidth(_ name: String) -> CGFloat {
        name == "checkmark" ? Style.icon : Style.refIcon
    }

    /// SF Symbols in the badge text color, drawn at a size that fills their slot (the cloud and tag are 16 pt wide at
    /// 12 pt, scaled down to 15; at 10.5 pt they stayed 14).
    @MainActor private static func symbol(_ name: String) -> NSImage? {
        if let cached = symbols[name] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: name == "checkmark" ? 10.5 : 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Palette.graphBadgeText]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        symbols[name] = image
        return image
    }

    @MainActor private static var symbols: [String: NSImage?] = [:]

    private static func icons(_ badge: RefBadge) -> (leading: [String], trailing: [String]) {
        switch badge.kind {
        case .branch(let isLocal, let isRemote, let isHead):
            return (isHead ? ["checkmark"] : [], (isLocal ? ["laptopcomputer"] : []) + (isRemote ? ["cloud"] : []))
        case .tag: return (["tag"], [])
        case .head: return (["checkmark"], [])
        case .worktree: return (["folder"], [])
        }
    }

    private static func aheadBehind(_ badge: RefBadge) -> String? {
        var parts: [String] = []
        if badge.ahead > 0 { parts.append("↑\(badge.ahead)") }
        if badge.behind > 0 { parts.append("↓\(badge.behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The pull request chip's width: its icon and "#N".
    private static func pullChipWidth(_ pull: PullRequestChip) -> CGFloat {
        2 * Style.chipPadding + Style.icon + Style.iconGap
            + ceil((pull.text as NSString).size(withAttributes: Style.count).width)
    }

    /// The badge's width without its name, and its name's width. A pull request chip takes the place of the badge's
    /// right padding, `chipInset` from its edge.
    private static func widths(_ badge: RefBadge) -> (chrome: CGFloat, name: CGFloat) {
        let (leading, trailing) = icons(badge)
        var chrome = 2 * Style.padding + (leading + trailing).reduce(0) { $0 + iconWidth($1) + Style.iconGap }
        if let counts = aheadBehind(badge) {
            chrome += Style.iconGap + ceil((counts as NSString).size(withAttributes: Style.count).width)
        }
        if let pull = badge.pullRequest.map(PullRequestChip.init) {
            chrome += Style.iconGap + pullChipWidth(pull) + Style.chipInset - Style.padding
        }
        let name = ceil((badge.name as NSString).size(withAttributes: Style.text).width)
        return (chrome, name)
    }

    /// Where the badges are drawn: each shown badge's frame, the "+N" chip, and where the line to the node starts.
    private struct Layout {
        var badges: [(index: Int, rect: CGRect)] = []
        var chip: (text: String, rect: CGRect)?
        var lineStart: CGFloat = 0
    }

    /// The badge drawn at `point` (in this view), for its menu and its drag.
    func badge(at point: CGPoint) -> RefBadge? {
        guard let layout = layout() else { return nil }
        return layout.badges.first { $0.rect.contains(point) }.map { badges[$0.index] }
    }

    /// The pull request whose chip is drawn at `point` (in this view): a click there opens it.
    func pullRequest(at point: CGPoint) -> RefBadge.PullRequest? {
        guard let layout = layout() else { return nil }
        for (index, rect) in layout.badges {
            guard let pull = badges[index].pullRequest, Self.chipRect(PullRequestChip(pull), in: rect).contains(point)
            else { continue }
            return pull
        }
        return nil
    }

    /// The chip's frame inside its badge's: at the trailing end, `chipInset` from the badge's edges.
    private static func chipRect(_ pull: PullRequestChip, in rect: CGRect) -> CGRect {
        let width = min(pullChipWidth(pull), rect.width - 2 * Style.chipInset)
        return CGRect(x: rect.maxX - Style.chipInset - width, y: rect.minY + Style.chipInset,
                      width: max(0, width), height: max(0, rect.height - 2 * Style.chipInset))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout = layout(), let context = NSGraphicsContext.current?.cgContext else { return }
        for (index, rect) in layout.badges {
            drawBadge(badges[index], in: rect, context: context)
        }
        if let chip = layout.chip {
            drawChip(chip.text, in: chip.rect, context: context)
        }

        // The line to the node.
        Palette.graphLanes[color % Palette.graphLanes.count].setStroke()
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: layout.lineStart, y: bounds.midY))
        context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        context.strokePath()
    }

    private func layout() -> Layout? {
        guard !badges.isEmpty else { return nil }
        var layout = Layout()
        let height = min(Style.height, bounds.height - 2 * metrics.bandInset)
        let y = (bounds.height - height) / 2
        let available = bounds.width - Style.leading - Style.trailing
        let sizes = badges.map(Self.widths)

        // How many badges fit, keeping room for "+N" when some are left out.
        var shown = badges.count
        var total = sizes.reduce(0) { $0 + $1.chrome + $1.name } + CGFloat(badges.count - 1) * Style.gap
        while shown > 1, total + (shown < badges.count ? chipWidth(badges.count - shown) + Style.gap : 0) > available {
            total -= sizes[shown - 1].chrome + sizes[shown - 1].name + Style.gap
            shown -= 1
        }
        // A lone first badge keeps at least `minimumName` of its name: then "+N" gives way.
        let minimumName: CGFloat = 40
        let showsChip = shown < badges.count
            && (shown > 1 || available - chipWidth(badges.count - shown) - Style.gap - sizes[0].chrome >= minimumName)
        let chip = showsChip ? chipWidth(badges.count - shown) + Style.gap : 0

        var x = Style.leading
        for index in 0..<shown {
            let room = available - (x - Style.leading) - chip
            let width = min(sizes[index].chrome + sizes[index].name, room)
            guard width > sizes[index].chrome + 12 || index == 0 else { break }
            layout.badges.append((index, CGRect(x: x, y: y, width: max(width, sizes[index].chrome), height: height)))
            x += width + Style.gap
        }
        if showsChip {
            let width = chipWidth(badges.count - shown)
            layout.chip = ("+\(badges.count - shown)", CGRect(x: x, y: y, width: width, height: height))
            x += width + Style.gap
        }
        layout.lineStart = x - Style.gap
        return layout
    }

    /// An image of `badge` alone, for its drag.
    func dragImage(of badge: RefBadge, scale: CGFloat) -> NSImage {
        let size = Self.widths(badge)
        let rect = CGRect(x: 0, y: 0, width: size.chrome + size.name, height: Style.height)
        let image = NSImage(size: rect.size)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((rect.width * scale).rounded(.up)),
            pixelsHigh: Int((rect.height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return image }
        bitmap.size = rect.size
        let context = bitmapContext.cgContext
        context.scaleBy(x: scale, y: scale)
        // Drawn top-down, as in the cell.
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawBadge(badge, in: rect, context: context)
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(bitmap)
        return image
    }

    private func chipWidth(_ count: Int) -> CGFloat {
        2 * Style.padding + ceil(("+\(count)" as NSString).size(withAttributes: Style.count).width)
    }

    private func drawChip(_ text: String, in rect: CGRect, context: CGContext) {
        Palette.graphTagFill.setFill()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: Style.radius, cornerHeight: Style.radius, transform: nil))
        context.fillPath()
        let size = (text as NSString).size(withAttributes: Style.count)
        (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                withAttributes: Style.count)
    }

    private func drawBadge(_ badge: RefBadge, in rect: CGRect, context: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: Style.radius, cornerHeight: Style.radius, transform: nil)
        if case .tag = badge.kind {
            Palette.graphTagFill.setFill()
        } else {
            Palette.graphBadgeFills[color % Palette.graphBadgeFills.count].setFill()
        }
        // No border, not even on HEAD's branch: its check icon marks it (user, 2026-11-13).
        context.addPath(path)
        context.fillPath()

        let (leading, trailing) = Self.icons(badge)
        var x = rect.minX + Style.padding
        for name in leading {
            drawIcon(name, x: x, midY: rect.midY)
            x += Self.iconWidth(name) + Style.iconGap
        }
        var trailingX = rect.maxX - Style.padding
        if let pull = badge.pullRequest.map(PullRequestChip.init) {
            let chip = Self.chipRect(pull, in: rect)
            drawPullRequestChip(pull, in: chip, context: context)
            trailingX = chip.minX - Style.iconGap
        }
        for name in trailing.reversed() {
            trailingX -= Self.iconWidth(name)
            drawIcon(name, x: trailingX, midY: rect.midY)
            trailingX -= Style.iconGap
        }
        if let counts = Self.aheadBehind(badge) {
            let size = (counts as NSString).size(withAttributes: Style.count)
            trailingX -= ceil(size.width)
            (counts as NSString).draw(at: CGPoint(x: trailingX, y: rect.midY - size.height / 2),
                                      withAttributes: Style.count)
            trailingX -= Style.iconGap
        }
        let lineHeight = ceil(Style.font.ascender - Style.font.descender + Style.font.leading)
        let textRect = CGRect(x: x, y: rect.midY - lineHeight / 2, width: max(0, trailingX - x), height: lineHeight)
        (badge.name as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: Style.text)
    }

    /// The pull icon and "#N" on GitHub's open green (or draft grey).
    private func drawPullRequestChip(_ pull: PullRequestChip, in rect: CGRect, context: CGContext) {
        (pull.isDraft ? Palette.graphPullDraftFill : Palette.graphPullOpenFill).setFill()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: Style.chipRadius, cornerHeight: Style.chipRadius,
                               transform: nil))
        context.fillPath()
        context.saveGState()
        context.clip(to: rect)
        let x = rect.minX + Style.chipPadding
        drawIcon("arrow.triangle.pull", x: x, midY: rect.midY, slot: Style.icon)
        let size = (pull.text as NSString).size(withAttributes: Style.count)
        (pull.text as NSString).draw(at: CGPoint(x: x + Style.icon + Style.iconGap, y: rect.midY - size.height / 2),
                                     withAttributes: Style.count)
        context.restoreGState()
    }

    private func drawIcon(_ name: String, x: CGFloat, midY: CGFloat) {
        drawIcon(name, x: x, midY: midY, slot: Self.iconWidth(name))
    }

    private func drawIcon(_ name: String, x: CGFloat, midY: CGFloat, slot: CGFloat) {
        guard let image = Self.symbol(name) else { return }
        let size = image.size
        let scale = min(1, slot / max(size.width, size.height))
        let width = size.width * scale
        let height = size.height * scale
        image.draw(in: CGRect(x: x + (slot - width) / 2, y: midY - height / 2, width: width, height: height))
    }
}

/// What a pull request chip draws.
private struct PullRequestChip {
    let text: String
    let isDraft: Bool

    init(_ pull: RefBadge.PullRequest) {
        text = "#\(pull.number)"
        isDraft = pull.isDraft
    }
}

// MARK: - Text

/// A text column's cell: one line, vertically centered, truncated with "…". `detail` follows the text in the
/// secondary color (the WIP row's change counts).
final class GraphTextCellView: NSView {
    enum Tone { case primary, secondary }

    var text = "" { didSet { setAccessibilityLabel(text) } }
    var detail: String?
    var tone = Tone.primary
    var isItalic = false

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
        static let font = NSFont.systemFont(ofSize: 12)
        static let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        static let paragraph: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            return style
        }()
        static func attributes(_ tone: Tone, italic: Bool) -> [NSAttributedString.Key: Any] {
            [.font: italic ? Style.italic : Style.font, .paragraphStyle: paragraph,
             .foregroundColor: tone == .primary ? NSColor.labelColor : NSColor.secondaryLabelColor]
        }
        static let primary = attributes(.primary, italic: false)
        static let secondary = attributes(.secondary, italic: false)
        static let primaryItalic = attributes(.primary, italic: true)
        static let secondaryItalic = attributes(.secondary, italic: true)
        static let padding: CGFloat = 8
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let attributes = switch (tone, isItalic) {
        case (.primary, false): Style.primary
        case (.secondary, false): Style.secondary
        case (.primary, true): Style.primaryItalic
        case (.secondary, true): Style.secondaryItalic
        }
        let lineHeight = ceil(Style.font.ascender - Style.font.descender + Style.font.leading)
        let rect = CGRect(x: Style.padding, y: (bounds.height - lineHeight) / 2,
                          width: max(0, bounds.width - 2 * Style.padding), height: lineHeight)
        let string: NSAttributedString
        if let detail {
            let combined = NSMutableAttributedString(string: text, attributes: attributes)
            combined.append(NSAttributedString(string: "  " + detail, attributes: Style.secondary))
            string = combined
        } else {
            string = NSAttributedString(string: text, attributes: attributes)
        }
        string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - Row and header

/// A graph row: the selection is a neutral rounded fill with a 1 pt edge (no accent, no white text), drawn under the
/// cells so the lanes stay on top.
final class GraphRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        Palette.graphSelection.setFill()
        path.fill()
        Palette.graphSelectionBorder.setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
        edge.lineWidth = 1
        edge.stroke()
    }
}

/// The column titles as gk shows them: small uppercase secondary text on the card's own fill (opaque, so scrolled rows
/// never show through it); a hairline below.
final class GraphHeaderView: NSTableHeaderView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Palette.graphSurface.setFill()
        dirtyRect.fill()
        guard let tableView else { return }
        for index in tableView.tableColumns.indices {
            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }
            tableView.tableColumns[index].headerCell.draw(withFrame: rect, in: self)
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: isFlipped ? bounds.maxY - 1 : bounds.minY, width: bounds.width, height: 1).fill()
    }
}

final class GraphHeaderCell: NSTableHeaderCell {
    @MainActor private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
        .kern: 0.6,
    ]

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let title = stringValue.uppercased() as NSString
        let size = title.size(withAttributes: Self.attributes)
        let rect = NSRect(x: cellFrame.minX + 8, y: cellFrame.midY - size.height / 2,
                          width: max(0, cellFrame.width - 12), height: size.height)
        title.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                   attributes: Self.attributes)
        // A hairline between columns, like the resize handle's place.
        NSColor.separatorColor.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 6, width: 1, height: max(0, cellFrame.height - 12)).fill()
    }
}
