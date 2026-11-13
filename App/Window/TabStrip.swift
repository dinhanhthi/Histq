// The header's tab strip (Rex style): the window's tabs in one capsule track, then New tab, Settings and the tab list.
import AppKit
import SwiftUI

/// Sizes of the tab strip. The tabs share one width, between `minTabWidth` and `maxTabWidth`; past that the track
/// scrolls.
private enum TabStripMetrics {
    static let trackHeight: CGFloat = 30
    /// Between the track's edge and the tabs.
    static let trackInset: CGFloat = 2
    static let minTabWidth: CGFloat = 96
    static let maxTabWidth: CGFloat = 200
    /// The close button's square, and the matching slot before the title (the profile color dot, Phase 7).
    static let slot: CGFloat = 16
    /// How far a press moves before it reorders the tab.
    static let dragThreshold: CGFloat = 5
}

/// The window's tabs and the header's trailing buttons. A press on a tab selects it at once (on mouse-down); a drag
/// past a few points reorders it.
struct TabStrip: View {
    @Environment(WindowModel.self) private var model
    @State private var showingTabList = false

    var body: some View {
        HStack(spacing: 12) {
            TabTrack(model: model)
            HStack(spacing: 14) {
                Button { model.openTab(nil) } label: {
                    Label("New Tab", systemImage: "plus")
                }
                .help("New Tab")
                Button { model.toggleSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .foregroundStyle(model.navigation.page == .settings ? Color.primary : Color.secondary)
                .help("Settings")
                Button { showingTabList.toggle() } label: {
                    Label("All Tabs", systemImage: "chevron.down")
                }
                .help("All Tabs")
                .popover(isPresented: $showingTabList, arrowEdge: .bottom) {
                    TabListPopover(model: model, isPresented: $showingTabList)
                }
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .buttonStyle(RowIconButtonStyle())
            .padding(.horizontal, 5)
            .background(WindowDragBlocker())
        }
        .padding(.trailing, 12)
    }
}

/// The tabs in a capsule track: equal widths, a hairline between two unselected tabs, a lighter capsule for the
/// selected one that slides to the next selection.
private struct TabTrack: View {
    let model: WindowModel
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tab under the current mouse press, so a press selects once.
    @State private var pressedID: WindowModel.Tab.ID?
    /// The dragged tab, its offset, and the index it came from and would land at. `dragFrom`/`dragTarget` stay stale
    /// after a cancelled drag on purpose: clearing them would change the neighbors' animation value and cancel the
    /// slide back.
    @State private var draggedID: WindowModel.Tab.ID?
    @State private var dragOffset: CGFloat = 0
    @State private var dragFrom = 0
    @State private var dragTarget = 0

    var body: some View {
        GeometryReader { proxy in
            let count = model.tabs.count
            let inset = TabStripMetrics.trackInset
            let tabWidth = min(TabStripMetrics.maxTabWidth,
                               max(TabStripMetrics.minTabWidth, (proxy.size.width - 2 * inset) / CGFloat(max(count, 1))))
            let rowWidth = tabWidth * CGFloat(count) + 2 * inset
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    row(tabWidth: tabWidth)
                }
                .scrollDisabled(rowWidth <= proxy.size.width)
                .frame(width: min(rowWidth, proxy.size.width))
                .clipShape(Capsule())
                .modifier(TrackBackground())
                .background(WindowDragBlocker())
                .onChange(of: model.selectedTabID) { _, id in
                    guard let id else { return }
                    withAnimation(animation) { scroller.scrollTo(id) }
                }
            }
            // Only the track takes clicks: the empty space after it drags the window.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: TabStripMetrics.trackHeight)
    }

    private var animation: Animation? { reduceMotion ? nil : Motion.standard }

    private func row(tabWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                let selected = tab.id == model.selectedTabID
                let dragged = tab.id == draggedID
                TabItem(title: tab.title, help: tab.repoURL?.path ?? tab.title, selected: selected,
                        dragged: dragged, namespace: namespace,
                        onSelect: { model.selectTab(id: tab.id) },
                        onClose: { close(tab.id) })
                    .frame(width: tabWidth)
                    .overlay(alignment: .leading) {
                        if index > 0, showsSeparator(before: index) {
                            Rectangle()
                                .fill(Palette.tabSeparator)
                                .frame(width: 1, height: 14)
                                .offset(x: -0.5)
                                .allowsHitTesting(false)
                        }
                    }
                    .offset(x: offset(of: index, id: tab.id, step: tabWidth))
                    // Neighbors slide aside; the dragged tab tracks the pointer without lag.
                    .animation(draggedID != nil && !dragged ? animation : nil, value: dragTarget)
                    .zIndex(dragged ? 1 : 0)
                    .gesture(press(tab.id, index: index, step: tabWidth))
                    .id(tab.id)
            }
        }
        .padding(TabStripMetrics.trackInset)
        // The selected capsule slides, also for a selection made elsewhere (a menu, the tab list).
        .animation(animation, value: model.selectedTabID)
    }

    /// No hairline next to the selected tab, nor while a tab is dragged.
    private func showsSeparator(before index: Int) -> Bool {
        guard draggedID == nil else { return false }
        let tabs = model.tabs
        return tabs[index].id != model.selectedTabID && tabs[index - 1].id != model.selectedTabID
    }

    /// The dragged tab follows the pointer; the tabs between its old and new place shift by one tab.
    private func offset(of index: Int, id: WindowModel.Tab.ID, step: CGFloat) -> CGFloat {
        guard let draggedID else { return 0 }
        if id == draggedID { return dragOffset }
        if dragFrom < dragTarget, index > dragFrom, index <= dragTarget { return -step }
        if dragTarget < dragFrom, index >= dragTarget, index < dragFrom { return step }
        return 0
    }

    /// Zero distance, so the tab is selected on mouse-down (a tap would wait for mouse-up); past `dragThreshold` it
    /// reorders.
    private func press(_ id: WindowModel.Tab.ID, index: Int, step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                // `!= id` rather than `== nil`: a press that never ends (`onEnded` skipped) blocks only this tab.
                if pressedID != id {
                    pressedID = id
                    model.selectTab(id: id)
                }
                let translation = value.translation.width
                guard draggedID != nil || abs(translation) >= TabStripMetrics.dragThreshold else { return }
                if draggedID == nil {
                    draggedID = id
                    dragFrom = index
                    dragTarget = index
                }
                dragOffset = translation
                let target = min(max(dragFrom + Int((translation / step).rounded()), 0), model.tabs.count - 1)
                if target != dragTarget { dragTarget = target }
            }
            .onEnded { _ in
                pressedID = nil
                guard draggedID != nil else { return }
                if dragFrom == dragTarget {
                    // Back into its slot with the lifted look.
                    withAnimation(animation) {
                        dragOffset = 0
                        draggedID = nil
                    }
                } else {
                    // Reset without animation before the move, so the tabs render at their new places directly.
                    draggedID = nil
                    dragOffset = 0
                    model.moveTab(from: dragFrom, to: dragTarget)
                }
            }
    }

    /// A tab's close button; closing the last tab closes the window, like ⌘W.
    private func close(_ id: WindowModel.Tab.ID) {
        if !model.closeTab(id: id) { model.closeWindow() }
    }
}

/// Liquid Glass on macOS 26 (unless `--force-fallbacks`); before, a `Palette.tabFill` capsule with a 1 pt edge.
private struct TrackBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *), PlatformFeatures.liquidGlass {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(Capsule().fill(Palette.tabFill))
                .overlay(Capsule().strokeBorder(Palette.surfaceBorder, lineWidth: 1).allowsHitTesting(false))
        }
    }
}

/// One tab: its name, centered and cut with "…", and a close button while hovered.
private struct TabItem: View {
    let title: String
    let help: String
    let selected: Bool
    let dragged: Bool
    let namespace: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            // Phase 7: the tab's profile color dot goes in this slot.
            Color.clear.frame(width: TabStripMetrics.slot, height: TabStripMetrics.slot)
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
            if hovered && !dragged {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: TabStripMetrics.slot, height: TabStripMetrics.slot)
                }
                .buttonStyle(CloseButtonStyle())
                .help("Close Tab")
                .accessibilityLabel("Close \(title)")
            } else {
                Color.clear.frame(width: TabStripMetrics.slot, height: TabStripMetrics.slot)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background {
            if selected {
                Capsule()
                    .fill(Palette.selectedTabFill)
                    .overlay(Capsule().strokeBorder(Palette.selectedBorder, lineWidth: 1))
                    .matchedGeometryEffect(id: "selectedTab", in: namespace)
            } else if hovered || dragged {
                Capsule().fill(Palette.hoverFill)
            }
        }
        .contentShape(Capsule())
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
    }

    /// A small round highlight on hover, darker while pressed.
    private struct CloseButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            Highlight(configuration: configuration)
        }

        private struct Highlight: View {
            let configuration: ButtonStyleConfiguration
            @State private var hovered = false

            var body: some View {
                configuration.label
                    .foregroundStyle(hovered ? Color.primary : Color.secondary)
                    .background(Circle().fill(configuration.isPressed ? Palette.pressedFill
                                              : hovered ? Palette.hoverFill : .clear))
                    .contentShape(Circle())
                    .animation(Motion.hover, value: hovered)
                    .onHover { hovered = $0 }
            }
        }
    }
}

/// The chevron's popover: a search field and the tabs that match it. A click selects the tab at once and closes the
/// popover.
private struct TabListPopover: View {
    let model: WindowModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let matches = matchingTabs
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $query, prompt: Text("Search tabs"))
                .textFieldStyle(.settings)
                .labelsHidden()
                .focused($searchFocused)
            if matches.isEmpty {
                Text("No matching tabs")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: SidebarItemStyle.height)
            } else {
                ScrollView {
                    VStack(spacing: SidebarItemStyle.spacing) {
                        ForEach(matches) { tab in
                            Button {
                                model.selectTab(id: tab.id)
                                isPresented = false
                            } label: {
                                Label(tab.title, systemImage: tab.repoURL == nil ? "house" : "folder")
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .buttonStyle(SidebarItemStyle(selected: tab.id == model.selectedTabID))
                            .help(tab.repoURL?.path ?? tab.title)
                        }
                    }
                }
                .frame(height: min(320, CGFloat(matches.count) * (SidebarItemStyle.height + SidebarItemStyle.spacing)))
            }
        }
        .padding(10)
        .frame(width: 280)
        // Next run-loop turn, once the popover's window exists.
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    /// Tabs whose name or folder contains the query (case- and diacritic-insensitive); all tabs for an empty query.
    private var matchingTabs: [WindowModel.Tab] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return model.tabs }
        return model.tabs.filter {
            $0.title.localizedStandardContains(text) || ($0.repoURL?.path.localizedStandardContains(text) ?? false)
        }
    }
}
