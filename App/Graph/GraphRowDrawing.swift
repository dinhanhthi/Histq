// Draws one row of the commit graph with Core Graphics: the faint band in the node's lane color, the line from the
// row's ref badges to its node, the lane lines (rounded where they bend into or out of the node) and the node itself.
// Nothing here allocates per row beyond what Core Graphics needs: colors are palette tokens resolved at draw time and
// the initials' strings are cached.
import AppKit
import HistqCore

/// Sizes of the graph, from the row height (`PrefKey.rowDensity`).
struct GraphMetrics: Equatable {
    let rowHeight: CGFloat

    /// "compact", "regular" (the default) or "comfortable"; anything else reads as regular.
    init(density: String) {
        switch density {
        case "compact": rowHeight = 22
        case "comfortable": rowHeight = 34
        default: rowHeight = 28
        }
    }

    /// A commit's node (its avatar's circle).
    var nodeDiameter: CGFloat { (rowHeight * 0.65).rounded() }
    /// From one lane's center to the next: a node and a small gap.
    var laneWidth: CGFloat { nodeDiameter + 4 }
    /// Before lane 0.
    var leading: CGFloat { 6 }
    /// A merge commit's dot.
    var mergeDotDiameter: CGFloat { 8 }
    var lineWidth: CGFloat { 2 }
    /// The radius of a line's bend into or out of a node.
    var bendRadius: CGFloat { 6 }
    /// The band's and the badges' inset from the row's top and bottom.
    var bandInset: CGFloat { 3 }

    /// The center of `lane`, from the graph column's left edge.
    func x(lane: Int) -> CGFloat { leading + CGFloat(lane) * laneWidth + laneWidth / 2 }
}

/// What a row's node stands for.
enum GraphNodeStyle: Equatable {
    /// A commit: its author's initials (5.2 adds the avatar).
    case commit(initials: String)
    /// A merge commit: a small dot.
    case merge
    /// The working tree's changes: a dashed circle.
    case wip
    /// A stash: a small box.
    case stash
}

@MainActor
enum GraphRowDrawing {
    /// Draws `row` in `bounds` (a flipped view's bounds, the graph column's cell). `hasRefs` draws the line from the
    /// column's left edge (where the ref badges' line ends) to the node. `avatar`, when given, fills the node.
    static func draw(
        _ row: GraphRow, node: GraphNodeStyle, hasRefs: Bool, avatar: NSImage?, metrics: GraphMetrics,
        in bounds: CGRect, context: CGContext
    ) {
        let lanes = Palette.graphLanes
        let colorCount = lanes.count
        let nodeX = bounds.minX + metrics.x(lane: row.lane)
        let midY = bounds.midY
        let laneColor = lanes[row.color % colorCount]

        // The band, from the node to the column's edge, ending in a 2 pt bar in the lane color (gk's message marker).
        let band = CGRect(x: nodeX, y: bounds.minY + metrics.bandInset,
                          width: max(0, bounds.maxX - nodeX), height: bounds.height - 2 * metrics.bandInset)
        if band.width > 0 {
            Palette.graphLaneBands[row.color % colorCount].setFill()
            context.fill(band)
            laneColor.setFill()
            context.fill(CGRect(x: bounds.maxX - 2, y: band.minY, width: 2, height: band.height))
        }

        context.setLineWidth(metrics.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if hasRefs {
            laneColor.setStroke()
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: bounds.minX, y: midY))
            context.addLine(to: CGPoint(x: nodeX, y: midY))
            context.strokePath()
            context.setLineWidth(metrics.lineWidth)
        }

        for segment in row.top {
            stroke(segment, top: true, metrics: metrics, bounds: bounds, context: context)
        }
        for segment in row.bottom {
            stroke(segment, top: false, metrics: metrics, bounds: bounds, context: context)
        }

        drawNode(node, color: laneColor, band: Palette.graphLaneBands[row.color % colorCount], avatar: avatar,
                 center: CGPoint(x: nodeX, y: midY), metrics: metrics, context: context)
    }

    /// One line piece. Top half: from the row's top edge at lane `from` to the center at lane `to`. Bottom half: from
    /// the center at `from` to the bottom edge at `to`. Bends turn with `bendRadius` (less when the lanes are closer).
    private static func stroke(
        _ segment: GraphSegment, top: Bool, metrics: GraphMetrics, bounds: CGRect, context: CGContext
    ) {
        let fromX = bounds.minX + metrics.x(lane: segment.from)
        let toX = bounds.minX + metrics.x(lane: segment.to)
        let midY = bounds.midY
        let radius = min(metrics.bendRadius, abs(toX - fromX), bounds.height / 2)
        Palette.graphLanes[segment.color % Palette.graphLanes.count].setStroke()
        if segment.isDashed { context.setLineDash(phase: 0, lengths: [3, 3]) }
        switch (segment.shape, top) {
        case (.bendIn, _):
            // Down lane `from`, then across to the node.
            context.move(to: CGPoint(x: fromX, y: bounds.minY))
            context.addArc(tangent1End: CGPoint(x: fromX, y: midY), tangent2End: CGPoint(x: toX, y: midY),
                           radius: radius)
            context.addLine(to: CGPoint(x: toX, y: midY))
        case (.bendOut, _):
            // Across from the node, then down lane `to`.
            context.move(to: CGPoint(x: fromX, y: midY))
            context.addArc(tangent1End: CGPoint(x: toX, y: midY), tangent2End: CGPoint(x: toX, y: bounds.maxY),
                           radius: radius)
            context.addLine(to: CGPoint(x: toX, y: bounds.maxY))
        case (.straight, true):
            context.move(to: CGPoint(x: fromX, y: bounds.minY))
            context.addLine(to: CGPoint(x: toX, y: midY))
        case (.straight, false):
            context.move(to: CGPoint(x: fromX, y: midY))
            context.addLine(to: CGPoint(x: toX, y: bounds.maxY))
        }
        context.strokePath()
        if segment.isDashed { context.setLineDash(phase: 0, lengths: []) }
    }

    private static func drawNode(
        _ node: GraphNodeStyle, color: NSColor, band: NSColor, avatar: NSImage?, center: CGPoint,
        metrics: GraphMetrics, context: CGContext
    ) {
        let diameter = metrics.nodeDiameter
        switch node {
        case .merge:
            let dot = metrics.mergeDotDiameter
            color.setFill()
            context.fillEllipse(in: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot))
        case .wip:
            let rect = CGRect(x: center.x - diameter / 2 + 1, y: center.y - diameter / 2 + 1,
                              width: diameter - 2, height: diameter - 2)
            Palette.graphSurface.setFill()
            context.fillEllipse(in: rect)
            band.setFill()
            context.fillEllipse(in: rect)
            color.setStroke()
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [2.5, 2.5])
            context.strokeEllipse(in: rect)
            context.setLineDash(phase: 0, lengths: [])
            context.setLineWidth(metrics.lineWidth)
        case .stash:
            let side = (diameter * 0.7).rounded()
            let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            Palette.graphSurface.setFill()
            context.addPath(path)
            context.fillPath()
            band.setFill()
            context.addPath(path)
            context.fillPath()
            color.setStroke()
            context.setLineWidth(1.5)
            context.addPath(path)
            context.strokePath()
            // The box's lid.
            context.move(to: CGPoint(x: rect.minX + 3, y: rect.midY - 1))
            context.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.midY - 1))
            context.strokePath()
            context.setLineWidth(metrics.lineWidth)
        case .commit(let initials):
            let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            color.setFill()
            context.fillEllipse(in: rect)
            if let avatar {
                // A 1.5 pt ring of the lane color around the avatar.
                let inner = rect.insetBy(dx: 1.5, dy: 1.5)
                context.saveGState()
                context.addEllipse(in: inner)
                context.clip()
                avatar.draw(in: inner)
                context.restoreGState()
            } else if !initials.isEmpty {
                let text = initialsString(initials, size: metrics.nodeDiameter)
                let size = text.size()
                text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
            }
        }
    }

    /// The initials' strings, by initials and node size: a few hundred at most in any repo.
    private static var initialsCache: [String: NSAttributedString] = [:]

    private static func initialsString(_ initials: String, size: CGFloat) -> NSAttributedString {
        let key = "\(initials)|\(size)"
        if let cached = initialsCache[key] { return cached }
        let font = NSFont.systemFont(ofSize: (size * 0.42).rounded(), weight: .semibold)
        let string = NSAttributedString(
            string: initials, attributes: [.font: font, .foregroundColor: Palette.graphNodeText])
        initialsCache[key] = string
        return string
    }

    /// Up to two letters: the first of the name's first and last words (`Ada Lovelace` -> `AL`).
    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
        guard let first = words.first?.first else { return "" }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }
}

/// The graph column's cell: draws its row with `GraphRowDrawing`. Reused by the table as it scrolls.
final class GraphCellView: NSView {
    var row: GraphRow?
    var node: GraphNodeStyle = .merge
    var hasRefs = false
    /// 5.2's avatar for the node; initials while nil.
    var avatar: NSImage?
    var metrics = GraphMetrics(density: "regular")

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let row, let context = NSGraphicsContext.current?.cgContext else { return }
        GraphRowDrawing.draw(row, node: node, hasRefs: hasRefs, avatar: avatar, metrics: metrics, in: bounds,
                             context: context)
    }
}
