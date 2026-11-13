// The main window: the toolbar in the traffic-light row (`HeaderToolbar`), the tab strip under it (or the vertical
// tabs, panel 0, left of the page), then the selected page, over the window glass. Settings is a modal over it
// (`ModalHost`).
import AppKit
import SwiftUI

/// A page of the window, left to right in the slide order: the selected tab, About.
enum Page: String, CaseIterable, Hashable {
    case home, about

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
    /// The tab row's container from the window's edges: the panels' inset.
    static let tabStripInset: CGFloat = RepoLayoutMetrics.inset
    /// Between the tab row's container and its tab pills.
    static let tabRowPadding: CGFloat = 4
    /// Concentric with the tab pills: their radius (28 pt capsules), the strip's 1 pt row inset, then the padding.
    static let tabRowRadius: CGFloat = 14 + 1 + tabRowPadding
    /// Between the tab strip and the top of every page (the repo panels, Welcome, About): the 8 pt gap of the cards.
    static let contentGap: CGFloat = SectionCardMetrics.spacing
}

struct MainView: View {
    @Bindable var navigation: Navigation
    @Environment(WindowModel.self) private var model
    /// The page on screen; it follows `navigation.page` with a slide.
    @State private var shownPage = Page.home
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// General › Tab position, applied live.
    @AppStorage(PrefKey.tabPosition.rawValue, store: Preferences.defaults) private var tabPosition = "top"

    var body: some View {
        let tabsOnLeft = TabPosition.resolved(tabPosition) == .left
        VStack(spacing: 0) {
            if !tabsOnLeft { tabRow }
            // The pages keep one place in the tree in both positions, so switching the position (from the Settings
            // modal over it) never rebuilds the page on screen.
            HStack(spacing: 0) {
                if tabsOnLeft {
                    // The pages' own leading inset is the gap after it.
                    VerticalTabsPanel()
                        .padding([.leading, .bottom], HeaderMetrics.tabStripInset)
                }
                // Rendered from `shownPage`, so the leaving page keeps its content while it slides out.
                ZStack {
                    switch shownPage {
                    case .home: TabContent().transition(pageTransition)
                    case .about: AboutPage().transition(pageTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            // Panel 0 and the page start at the top of the safe area, where the tab row does.
            .padding(.top, tabsOnLeft ? 0 : HeaderMetrics.contentGap)
        }
        // Blurred and disabled behind a modal or the palette; its own view reads that, so this body never reruns.
        .modifier(WindowBackdrop(model: model))
        // Whoever switches the page (a tab, About, a menu), it slides the same way.
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
        // ⌘K / the toolbar's Search: over the tabs and the page, under the toolbar.
        .overlay { CommandPaletteOverlay(model: model) }
        // Settings, the forms, confirmations and rebase cards, drawn like the palette (same place in the window).
        .overlay { ModalHost(model: model) }
        .modifier(HardTopScrollEdge())
    }

    /// The tab strip, full width under the toolbar, then the menus' running operation, in one `PanelContainer` like
    /// the panels below. Empty space in the row drags the window, like the toolbar's: the drag area lies over the
    /// container's fill (padding 0, inset inside), so the whole container drags, not only the gaps around it.
    private var tabRow: some View {
        PanelContainer(padding: 0, cornerRadius: HeaderMetrics.tabRowRadius) {
            HStack(spacing: 0) {
                TabStrip()
                TabRowStatus(model: model)
            }
            .padding(HeaderMetrics.tabRowPadding)
            .background(WindowDragArea())
        }
        .padding(.horizontal, HeaderMetrics.tabStripInset)
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

/// Applies `ModalBackdrop` while the window shows Settings, a modal or the palette. Only this modifier reads that
/// state.
private struct WindowBackdrop: ViewModifier {
    let model: WindowModel

    func body(content: Content) -> some View {
        content.modifier(ModalBackdrop(isActive: model.isShowingModal))
    }
}

/// The selected tab's area: the three-panel layout of a repo tab, "Repo not found" for a restored repo that is gone,
/// or the Welcome page of a new tab. A new identity
/// per tab: switching tabs shows the new tab's placeholder (or its Welcome state), never the old tab's view.
private struct TabContent: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        if let session = model.selectedSession {
            RepoLayoutView(session: session).id(session.id)
        } else if let index = model.selectedIndex, model.tabs[index].isMissing, let url = model.tabs[index].repoURL {
            RepoNotFoundView(model: model, tabID: model.tabs[index].id, url: url).id(model.tabs[index].id)
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
