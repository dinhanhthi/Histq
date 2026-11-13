// The main window: the toolbar in the traffic-light row (`HeaderToolbar`), the tab strip under it, then the selected
// page, over the window glass.
import AppKit
import SwiftUI

/// A page of the window, left to right in the slide order: the selected tab, Settings, About.
enum Page: String, CaseIterable, Hashable {
    case home, settings, about

    /// Its place in the order, for the slide direction.
    fileprivate var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// The selected page, owned by the AppDelegate so its menus can open a page before the window exists.
@Observable
@MainActor
final class Navigation {
    var page: Page = .home {
        didSet { forward = page.order >= oldValue.order }
    }

    /// The last page change went to a page further right.
    private(set) var forward = true
}

/// The rows under the toolbar. The tab strip starts at the top of the safe area, so it sits under the toolbar, and
/// under the native window tab bar when one shows (Phase 8).
enum HeaderMetrics {
    /// The tab strip from the window's leading edge: the cards' inset.
    static let tabStripInset: CGFloat = RepoLayoutMetrics.inset
    /// Between the tab strip and the top of every page (the repo panels, Welcome, Settings, About): the 8 pt gap of
    /// the cards.
    static let contentGap: CGFloat = SectionCardMetrics.spacing
}

struct MainView: View {
    @Bindable var navigation: Navigation
    @Environment(WindowModel.self) private var model
    /// The page on screen; it follows `navigation.page` with a slide.
    @State private var shownPage = Page.home
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            tabRow
            // Rendered from `shownPage`, so the leaving page keeps its content while it slides out.
            ZStack {
                switch shownPage {
                case .home: TabContent().transition(pageTransition)
                // The scaffold keeps one settings layout; both define `SettingsRoot`.
                case .settings: SettingsRoot().transition(pageTransition)
                case .about: AboutPage().transition(pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .padding(.top, HeaderMetrics.contentGap)
        }
        // Whoever switches the page (a tab, the Settings button, a menu), it slides the same way.
        .onChange(of: navigation.page, initial: true) { old, new in
            guard old != new else {
                shownPage = new
                return
            }
            withAnimation(Motion.standard) { shownPage = new }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowGlass().ignoresSafeArea())
        // A band behind the toolbar row (drawn above it by AppKit), so scrolled content never shows through the
        // transparent title bar; the same glass as the window, so toolbar and content still read as one.
        .overlay {
            GeometryReader { proxy in
                WindowGlass()
                    .frame(height: proxy.safeAreaInsets.top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(.container, edges: .top)
            }
            .allowsHitTesting(false)
        }
        .modifier(HardTopScrollEdge())
    }

    /// The tab strip, full width under the toolbar, then the menus' running operation. Empty space in the row drags
    /// the window, like the toolbar's.
    private var tabRow: some View {
        HStack(spacing: 0) {
            TabStrip()
            TabRowStatus(model: model)
        }
        .padding(.leading, HeaderMetrics.tabStripInset)
        .background(WindowDragArea())
    }

    /// Pages slide a little in their order; the leaving page fades out faster, so the two never show through each
    /// other. A fade only under Reduce Motion.
    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let travel: CGFloat = navigation.forward ? 24 : -24
        return .asymmetric(
            insertion: .offset(x: travel).combined(with: .opacity),
            removal: .offset(x: -travel).combined(with: .opacity).animation(Motion.exit))
    }
}

/// The selected tab's area: the three-panel layout of a repo tab, or the Welcome page of a new tab. A new identity
/// per tab: switching tabs shows the new tab's placeholder (or its Welcome state), never the old tab's view.
private struct TabContent: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        if let session = model.selectedSession {
            RepoLayoutView(session: session).id(session.id)
        } else if let id = model.selectedTabID {
            WelcomeView(model: model.welcome(for: id)).id(id)
        }
    }
}

/// The selected repo's operations started from a menu (a merge, a rebase…), which have no toolbar button to show
/// their progress on.
private struct TabRowStatus: View {
    let model: WindowModel

    var body: some View {
        if let session = model.selectedSession {
            RunningStatus(session: session)
                .frame(maxWidth: 240, alignment: .trailing)
                .padding(.trailing, 8)
        }
    }
}

/// The app's name and version from the bundle.
private struct AboutPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(Self.name).font(.title2.weight(.semibold))
            Text("Version \(Self.version)")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Histq"
    }

    /// "0.1.0 (1)".
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

// MARK: - Window dragging (Dblore `WindowUtilities.swift`; Phase 8.1 moves these into `App/Window/WindowUtilities.swift`)

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
