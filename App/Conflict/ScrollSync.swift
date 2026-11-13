// Keeps the conflict editor's three panes (A, B and Output) on the same part of the file: scrolling one scrolls the
// other two to the line the merge's line map gives (the same offset inside the same region). Every pane has fixed
// 18 pt lines from the top of its document view, so a scroll offset is a line number and back.
import AppKit
import HistqCore

/// The scroll link between the panes. Each pane registers its scroll view; the editor hands it the current merge (its
/// regions move as Output changes). A guard keeps the scrolls it makes from echoing back.
@MainActor
final class ScrollSync: NSObject {
    /// The merge whose line map links the panes; nil until it loads.
    var merge: ThreeWayMerge?

    private final class Entry {
        weak var scroll: NSScrollView?
        init(_ scroll: NSScrollView) { self.scroll = scroll }
    }

    private var panes: [ThreeWayMerge.Pane: Entry] = [:]
    /// True while this object scrolls the other panes, so their own bounds changes are not synced back.
    private var syncing = false

    /// Starts following `scroll`'s clip view as `pane`. Registering a pane again replaces the old view.
    func register(_ scroll: NSScrollView, as pane: ThreeWayMerge.Pane) {
        if let old = panes[pane]?.scroll {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old.contentView)
        }
        panes[pane] = Entry(scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
    }

    @objc private func boundsChanged(_ notification: Notification) {
        guard !syncing, let clip = notification.object as? NSClipView,
              let pane = panes.first(where: { $0.value.scroll?.contentView === clip })?.key,
              let merge
        else { return }
        let position = clip.bounds.minY / ConflictLayout.lineHeight
        let line = Int(position.rounded(.down))
        let fraction = position - CGFloat(line)
        syncing = true
        defer { syncing = false }
        for (other, entry) in panes where other != pane {
            guard let scroll = entry.scroll else { continue }
            let mapped = merge.line(max(0, line), in: pane, to: other)
            scrollTop(scroll, to: (CGFloat(mapped) + fraction) * ConflictLayout.lineHeight)
        }
    }

    /// ▲ ▼: every pane shows conflict `k` (0-based) a few lines below its top.
    func jump(toConflict k: Int) {
        guard let merge, merge.conflictRegions.indices.contains(k) else { return }
        syncing = true
        defer { syncing = false }
        for (pane, entry) in panes {
            guard let scroll = entry.scroll else { continue }
            let line = max(0, merge.conflictStart(k, in: pane) - 3)
            scrollTop(scroll, to: CGFloat(line) * ConflictLayout.lineHeight)
        }
    }

    /// Scrolls so the document's `y` is at the top, within the document's bounds; the horizontal offset stays.
    private func scrollTop(_ scroll: NSScrollView, to y: CGFloat) {
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y = y
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }
}
