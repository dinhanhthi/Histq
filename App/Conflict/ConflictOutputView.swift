// The conflict editor's Output: the merged file in an editable NSTextView (plain text, fixed 18 pt lines that never
// wrap) with a line-number ruler. Unresolved conflicts are tinted magenta, lines taken from A blue and from B gold,
// typed lines grey. A tick changes only the characters that differ; a typed edit becomes a manual override of the
// regions it touched in `ThreeWayMerge`, and the text then matches the merge again, so what is saved is what shows.
import AppKit
import HistqCore
import SwiftUI

/// Output's text view and ruler. `revision` changes with every tick or edit; `loadID` with every load.
struct ConflictOutputView: NSViewRepresentable {
    let merge: ThreeWayMerge
    let revision: Int
    let loadID: Int
    let sync: ScrollSync
    /// False for a file that is not UTF-8: a typed edit would save the region's U+FFFD display text over its bytes, so
    /// Output is read-only there and only ticks (byte-exact) resolve it.
    var isEditable = true
    /// A typed edit: the new text of the first region of the range (the others become empty). Returns the new merge.
    var onEdit: @MainActor (String, ClosedRange<Int>) -> ThreeWayMerge? = { _, _ in nil }

    func makeCoordinator() -> ConflictOutputController { ConflictOutputController() }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1: fixed line fragments make every line exactly `lineHeight` tall from the top, as in the panes.
        let textView = ConflictTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.insertionPointColor = .white
        textView.font = DiffLayout.font
        textView.textColor = Palette.diffText
        textView.defaultParagraphStyle = ConflictOutputController.paragraph
        textView.typingAttributes = ConflictOutputController.attributes
        textView.textContainerInset = NSSize(width: 6, height: 0)
        // No wrap: the text view grows sideways with its longest line.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let ruler = ConflictLineRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.attach(textView, ruler: ruler)
        sync.register(scroll, as: .output)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }
}

/// Keeps the text view equal to the merge's Output and turns typing into manual overrides.
@MainActor
final class ConflictOutputController: NSObject, NSTextViewDelegate {
    private weak var textView: ConflictTextView?
    private weak var ruler: ConflictLineRuler?
    private var view: ConflictOutputView?
    private var shown: (loadID: Int, revision: Int)?
    /// The merge the text shows.
    private var merge: ThreeWayMerge?
    /// True while the controller itself changes the text: not a user edit.
    private var isSyncing = false
    /// A user edit between `shouldChangeTextIn` and `textDidChange`: the regions it touches and their characters
    /// before it.
    private var pending: (regions: ClosedRange<Int>, span: NSRange, delta: Int)?

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = ConflictLayout.lineHeight
        style.maximumLineHeight = ConflictLayout.lineHeight
        style.tabStops = []
        style.defaultTabInterval = CGFloat(DiffLayout.tabWidth) * DiffLayout.charWidth
        style.lineBreakMode = .byClipping
        return style
    }()

    static let attributes: [NSAttributedString.Key: Any] = [
        .font: DiffLayout.font, .foregroundColor: Palette.diffText, .paragraphStyle: paragraph,
        // The fixed line is taller than the font: lift the glyphs to its middle.
        .baselineOffset: (ConflictLayout.lineHeight - (DiffLayout.font.ascender - DiffLayout.font.descender)) / 2,
    ]

    func attach(_ textView: ConflictTextView, ruler: ConflictLineRuler) {
        self.textView = textView
        self.ruler = ruler
        textView.delegate = self
        textView.controller = self
        // The ruler draws the numbers of the lines on screen: it redraws with every scroll.
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @objc private func scrolled() {
        ruler?.needsDisplay = true
    }

    func update(_ view: ConflictOutputView) {
        self.view = view
        if textView?.isEditable != view.isEditable { textView?.isEditable = view.isEditable }
        guard shown?.loadID != view.loadID || shown?.revision != view.revision else { return }
        shown = (view.loadID, view.revision)
        show(view.merge)
    }

    /// Makes the text equal to `merge`'s Output, replacing only the characters between the common start and end (the
    /// scroll offset and the caret stay where they were), then redraws the tints and the numbers.
    private func show(_ merge: ThreeWayMerge) {
        self.merge = merge
        guard let textView, let storage = textView.textStorage else { return }
        let new = merge.outputText as NSString
        let old = storage.string as NSString
        if !new.isEqual(to: old as String) {
            let oldLength = old.length
            let newLength = new.length
            let shorter = min(oldLength, newLength)
            var prefix = 0
            while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < shorter - prefix,
                  old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix)
            {
                suffix += 1
            }
            let replaced = NSRange(location: prefix, length: oldLength - prefix - suffix)
            let text = new.substring(with: NSRange(location: prefix, length: newLength - prefix - suffix))
            let selection = textView.selectedRange()
            isSyncing = true
            storage.beginEditing()
            storage.replaceCharacters(in: replaced, with: NSAttributedString(string: text, attributes: Self.attributes))
            storage.endEditing()
            isSyncing = false
            if selection.location >= NSMaxRange(replaced) {
                let moved = selection.location + (newLength - oldLength)
                textView.setSelectedRange(NSRange(location: min(moved, newLength), length: 0))
            } else if selection.location > replaced.location {
                textView.setSelectedRange(NSRange(location: min(replaced.location + (text as NSString).length, newLength),
                                                  length: 0))
            }
        }
        textView.tints = Self.tints(merge)
        textView.needsDisplay = true
        ruler?.lineCount = merge.outputLines.count
        ruler?.needsDisplay = true
    }

    /// The band of each Output line: magenta for an unresolved conflict (its base text), blue for lines ticked in A,
    /// gold for lines ticked in B, grey for typed lines. Lines outside these have none.
    private static func tints(_ merge: ThreeWayMerge) -> [Int: (fill: NSColor, bar: NSColor?)] {
        var tints: [Int: (fill: NSColor, bar: NSColor?)] = [:]
        for region in merge.regions {
            if region.isManual {
                for line in region.output { tints[line] = (Palette.conflictEditedFill, nil) }
            } else if region.kind == .conflict {
                if region.isUnresolved {
                    for line in region.output {
                        tints[line] = (Palette.conflictUnresolvedFill, Palette.conflictUnresolved)
                    }
                } else {
                    let fromA = region.a.count { merge.isTicked(.a, line: $0) }
                    for (offset, line) in region.output.enumerated() {
                        tints[line] = offset < fromA
                            ? (Palette.conflictAFill, Palette.conflictA) : (Palette.conflictBFill, Palette.conflictB)
                    }
                }
            }
        }
        return tints
    }

    // MARK: Editing

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !isSyncing else { return true }
        guard let merge, let replacementString else { return false }
        // The UTF-16 offset where each Output line starts, and the end.
        var starts = [0]
        starts.reserveCapacity(merge.outputLines.count + 1)
        for line in merge.outputLines { starts.append(starts[starts.count - 1] + line.utf16.count) }
        func line(at offset: Int) -> Int {
            var low = 0
            var high = starts.count - 1
            while low < high { // the last line starting at or before `offset`
                let mid = (low + high + 1) / 2
                if starts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low
        }
        // Past the last line (typing at the very end) belongs to the last region that has text.
        func region(of line: Int) -> Int? {
            if line < merge.outputLines.count { return merge.region(containing: line, in: .output) }
            return merge.regions.lastIndex { !$0.output.isEmpty } ?? merge.regions.indices.last
        }
        guard let first = region(of: line(at: range.location)),
              let last = region(of: line(at: max(range.location, NSMaxRange(range) - 1)))
        else { return false }
        let start = min(starts[min(merge.regions[first].output.lowerBound, starts.count - 1)], range.location)
        let end = starts[min(merge.regions[last].output.upperBound, starts.count - 1)]
        // An edit can reach past its regions' text only at the very end of Output (after its last line break).
        let spanEnd = max(end, NSMaxRange(range))
        pending = (first...last, NSRange(location: start, length: spanEnd - start),
                   (replacementString as NSString).length - range.length)
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !isSyncing, let pending, let textView, let view else { return }
        self.pending = nil
        let text = textView.string as NSString
        let span = NSRange(location: pending.span.location, length: max(0, pending.span.length + pending.delta))
        guard NSMaxRange(span) <= text.length else { return }
        guard let merge = view.onEdit(text.substring(with: span), pending.regions) else { return }
        // The merge may differ from what was typed (a line break between two regions comes back): show it.
        show(merge)
    }
}

/// Output's text view: draws each line's band behind the text, full width, at its fixed line position. Esc does
/// nothing here (no completion list).
final class ConflictTextView: NSTextView {
    weak var controller: ConflictOutputController?
    var tints: [Int: (fill: NSColor, bar: NSColor?)] = [:]

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let height = ConflictLayout.lineHeight
        let top = textContainerInset.height
        let first = max(0, Int(((rect.minY - top) / height).rounded(.down)))
        let last = Int(((rect.maxY - top) / height).rounded(.up))
        guard first <= last else { return }
        let width = max(bounds.width, visibleRect.maxX)
        for line in first...last {
            guard let tint = tints[line] else { continue }
            let y = top + CGFloat(line) * height
            tint.fill.setFill()
            NSRect(x: 0, y: y, width: width, height: height).fill(using: .sourceOver)
            if let bar = tint.bar {
                bar.setFill()
                NSRect(x: 0, y: y, width: ConflictLayout.barWidth, height: height).fill()
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {}
}

/// Output's line numbers, at the same fixed line positions as the text.
final class ConflictLineRuler: NSRulerView {
    var lineCount = 0 {
        didSet {
            let digits = max(3, String(lineCount).count)
            let thickness = CGFloat(digits) * DiffLayout.charWidth + 16
            if abs(ruleThickness - thickness) > 0.5 { ruleThickness = thickness }
        }
    }

    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 3 * DiffLayout.charWidth + 16
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }

    private static let attributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return [.font: DiffLayout.numberFont, .foregroundColor: Palette.diffLineNumber, .paragraphStyle: style]
    }()

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, lineCount > 0 else { return }
        let height = ConflictLayout.lineHeight
        let visible = textView.visibleRect
        let top = textView.textContainerInset.height
        let first = max(0, Int(((visible.minY - top) / height).rounded(.down)))
        let last = min(lineCount - 1, Int(((visible.maxY - top) / height).rounded(.up)))
        guard first <= last else { return }
        let numberHeight = DiffLayout.numberFont.boundingRectForFont.height
        for line in first...last {
            let y = convert(NSPoint(x: 0, y: top + CGFloat(line) * height), from: textView).y
            NSString(string: "\(line + 1)").draw(
                in: NSRect(x: 0, y: y + (height - numberHeight) / 2, width: ruleThickness - 8, height: height),
                withAttributes: Self.attributes)
        }
    }
}
