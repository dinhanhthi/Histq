// Window utilities (Dblore `WindowUtilities.swift`): the tab row's window dragging, and what joins the repo windows
// into one native window tab group.
import AppKit
import Observation
import SwiftUI

// MARK: - Window dragging

/// Behind the tab strip: a mouse-down on its empty space drags the window, like the toolbar's.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowDragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// Under the tab strip's interactive controls: the window is not movable while the pointer is over them, so a drag
/// reaches the SwiftUI gesture (a tab's reorder) instead of moving the window. AppKit asks the hosting view, not this
/// background view, whether a mouse-down moves the window.
struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragBlockerView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowDragBlockerView: NSView {
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { window?.isMovable = false }

        override func mouseExited(with event: NSEvent) { window?.isMovable = true }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // A control removed under the pointer (a closed tab) never gets mouseExited.
            if newWindow == nil { window?.isMovable = true }
            super.viewWillMove(toWindow: newWindow)
        }

        override nonisolated func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Native window tabs

extension NSWindow.TabbingIdentifier {
    /// Every repo window: they join one native tab group (Window › Merge All Windows, the tab bar's "+").
    static let histqDocument = NSWindow.TabbingIdentifier("com.math2it.histq.document")
}

/// What makes a repo window a native tab: the shared tabbing identifier, the "+" of the native tab bar and the title
/// its native tab shows. Its own toolbar (`HeaderToolbar`) stays: AppKit shows the selected tab's window with its
/// toolbar in row 1, the native tab bar in row 2 under it, and the content (the app's tab row first) starts below the
/// bar, at the top of the safe area.
@MainActor
enum DocumentWindow {
    /// Called once per window, before it shows. `openTab` opens a new Welcome window as a tab of the given window.
    static func configure(_ window: NSWindow, model: WindowModel, openTab: @escaping (NSWindow) -> Void) {
        window.tabbingIdentifier = .histqDocument
        window.tabbingMode = .automatic
        // Session restore (8.4) owns what windows reopen; AppKit restoring one would only bring back a bare window.
        window.isRestorable = false
        NewTabResponder.install(in: window, open: openTab)
        trackTitle(of: window, model: model)
    }

    /// Keeps `window.title` on the selected app tab's name ("New Tab" for a Welcome tab): the native tab, the Window
    /// menu and Mission Control show it; the title bar never draws it (`titleVisibility = .hidden`).
    private static func trackTitle(of window: NSWindow, model: WindowModel) {
        withObservationTracking {
            let title = model.selectedIndex.map { model.tabs[$0].title } ?? "Histq"
            if window.title != title { window.title = title }
        } onChange: { [weak window, weak model] in
            // Called before the change lands, off any isolation: read it on the main actor once it has.
            Task { @MainActor in
                guard let window, let model else { return }
                trackTitle(of: window, model: model)
            }
        }
    }
}

/// Answers the native tab bar's "+" (`newWindowForTab:`) right after the window, so the action knows which window's
/// tab group the new Welcome window joins (the app delegate, last in the chain, would only see the key window). AppKit
/// shows the "+" only while something in the window's responder chain answers it.
final class NewTabResponder: NSResponder {
    /// `nextResponder` does not retain: each window keeps its responder here.
    private static let responders = NSMapTable<NSWindow, NewTabResponder>.weakToStrongObjects()

    private weak var window: NSWindow?
    private let open: (NSWindow) -> Void

    private init(window: NSWindow, open: @escaping (NSWindow) -> Void) {
        self.window = window
        self.open = open
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    static func install(in window: NSWindow, open: @escaping (NSWindow) -> Void) {
        guard responders.object(forKey: window) == nil else { return }
        let responder = NewTabResponder(window: window, open: open)
        responder.nextResponder = window.nextResponder
        window.nextResponder = responder
        responders.setObject(responder, forKey: window)
    }

    override func newWindowForTab(_ sender: Any?) {
        guard let window else { return }
        open(window)
    }
}
