// The main window: the pages as tabs in the toolbar, the selected page under them, over the window glass.
import AppKit
import SwiftUI

/// A page of the toolbar's tabs, left to right. Adding one: a case, its `title`, its view in `MainView.body`.
enum Page: String, CaseIterable, Hashable {
    case home, settings, about

    var title: String {
        switch self {
        case .home: "Home"
        case .settings: "Settings"
        case .about: "About"
        }
    }

    /// Its place in the tabs, for the slide direction.
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

struct MainView: View {
    @Bindable var navigation: Navigation
    /// The page on screen; it follows `navigation.page` with a slide.
    @State private var shownPage = Page.home
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Rendered from `shownPage`, so the leaving page keeps its content while it slides out.
        ZStack {
            switch shownPage {
            case .home: HomePage().transition(pageTransition)
            // The scaffold keeps one settings layout; both define `SettingsRoot`.
            case .settings: SettingsRoot().transition(pageTransition)
            case .about: AboutPage().transition(pageTransition)
            }
        }
        // Whoever switches the page (tabs, menu), it slides the same way.
        .onChange(of: navigation.page, initial: true) { old, new in
            guard old != new else {
                shownPage = new
                return
            }
            withAnimation(Motion.standard) { shownPage = new }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowGlass().ignoresSafeArea())
        // A band behind the transparent title bar, so scrolled content never shows through it; the same glass as
        // the window, so the title bar and the content still read as one.
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // Placeholder logo: replace with the app's own image.
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Histq")
            }
            .hiddenSharedBackground()
            // Pushes the action and the tabs to the trailing edge, the logo alone at the leading edge.
            flexibleSpacer
            ToolbarItem {
                // Placeholder: the app's main action.
                ToolbarIconButton(systemImage: "plus", help: "New Item") {}
            }
            fixedSpacer
            ToolbarItem {
                CapsuleTabs(selection: $navigation.page, tabs: Page.allCases, title: { Text($0.title) })
                    // AppKit pads the sides less than the top and bottom.
                    .padding(.horizontal, 4)
                    .fixedSize()
            }
        }
    }

    /// Pages slide a little in their tab order; the leaving page fades out faster, so the two never show through
    /// each other. A fade only under Reduce Motion.
    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let travel: CGFloat = navigation.forward ? 24 : -24
        return .asymmetric(
            insertion: .offset(x: travel).combined(with: .opacity),
            removal: .offset(x: -travel).combined(with: .opacity).animation(Motion.exit))
    }

    /// Separates the capsules from the logo: a flexible space.
    @ToolbarContentBuilder private var flexibleSpacer: some ToolbarContent {
        if #available(macOS 26, *), PlatformFeatures.liquidGlass {
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem { Spacer() }
        }
    }

    /// Separates two capsules on macOS 26.
    @ToolbarContentBuilder private var fixedSpacer: some ToolbarContent {
        if #available(macOS 26, *), PlatformFeatures.liquidGlass {
            ToolbarSpacer(.fixed)
        }
    }
}

/// A sample page with every control of the style: replace it with the app's content.
private struct HomePage: View {
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Card").font(.headline)
                        Text("A solid surface with a 1 pt edge, on every macOS version.")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("Raised") {}
                                .buttonStyle(RaisedButtonStyle(horizontalPadding: 12))
                            Button {} label: { Text("Tinted").foregroundStyle(.white) }
                                .buttonStyle(RaisedButtonStyle(horizontalPadding: 12, tint: .accentColor))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(GlassCard())

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Raised card").font(.headline)
                        Text("A rim lit from above, a faint sheen and a soft shadow.")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 18) {
                            Button {} label: { Image(systemName: "square.and.arrow.up") }
                                .help("Share")
                            Button {} label: { Image(systemName: "doc.on.doc") }
                                .help("Copy")
                            Button {} label: { Image(systemName: "trash") }
                                .help("Delete")
                        }
                        .buttonStyle(RowIconButtonStyle())
                        .padding(.leading, 5)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(GlassCard(raised: true))
                }
                .padding(12)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {}
                    .buttonStyle(BottomBarButtonStyle())
                Button("Continue") {}
                    .buttonStyle(BottomBarButtonStyle(prominent: true))
            }
            .padding(12)
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
