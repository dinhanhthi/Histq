// Panel 0, the vertical tabs (General › Tab position: Left): the window's tabs as rows in their own
// `PanelContainer`, left of every page, with New tab, the command palette and the tab list at the bottom. The tab
// strip under the toolbar does not show then.
import SwiftUI

/// Where the window's app tabs show: the strip under the toolbar, or panel 0 on the left.
enum TabPosition: String {
    case top, left

    /// DEBUG `-HistqTabPosition left|top`, read once. It wins over the preference (as `-HistqAvatarMode` does) and is
    /// never written to it: outside a state dir the preferences are the user's own.
    private static let launchOverride = AppState.launchFlag("-HistqTabPosition").flatMap(TabPosition.init(rawValue:))

    /// The position for a stored `PrefKey.tabPosition` value; anything unknown reads as top.
    static func resolved(_ stored: String) -> TabPosition {
        launchOverride ?? TabPosition(rawValue: stored) ?? .top
    }

    /// The position for the preference stored now.
    static var current: TabPosition {
        resolved(Preferences.defaults.string(forKey: PrefKey.tabPosition.rawValue) ?? "")
    }
}

enum VerticalTabsMetrics {
    /// Panel 0's width, its container included. Fixed: the window's minimum width counts it.
    static let width: CGFloat = 150
}

/// The window's tabs top to bottom, the selected tab's running operation, then New tab, the command palette and the
/// tab list.
struct VerticalTabsPanel: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        PanelContainer {
            VStack(alignment: .leading, spacing: SectionCardMetrics.spacing) {
                VerticalTabList(model: model)
                VerticalTabsStatus(model: model)
                TabStripButtons(model: model, popoverEdge: .trailing)
            }
        }
        .frame(width: VerticalTabsMetrics.width)
    }
}

/// The tabs as Settings sidebar rows (`VerticalTabRow`): a press selects at once (on mouse-down), a drag past a few points
/// reorders.
private struct VerticalTabList: View {
    let model: WindowModel
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tab under the current mouse press, so a press selects once.
    @State private var pressedID: WindowModel.Tab.ID?
    /// The dragged tab, its offset, and the index it came from and would land at. `dragFrom`/`dragTarget` stay stale
    /// after a cancelled drag on purpose, as in the tab strip: clearing them would cancel the neighbors' slide back.
    @State private var draggedID: WindowModel.Tab.ID?
    @State private var dragOffset: CGFloat = 0
    @State private var dragFrom = 0
    @State private var dragTarget = 0

    private var step: CGFloat { SidebarItemStyle.height + SidebarItemStyle.spacing }
    private var animation: Animation? { reduceMotion ? nil : Motion.standard }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical, showsIndicators: false) {
                rows
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(WindowDragBlocker())
            .onChange(of: model.selectedTabID) { _, id in
                guard let id else { return }
                withAnimation(animation) { scroller.scrollTo(id) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var rows: some View {
        VStack(spacing: SidebarItemStyle.spacing) {
            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                let dragged = tab.id == draggedID
                // A tab not opened yet (filled in the background) has no session, so no dot.
                let profile = model.sessions[tab.id]?.profile
                VerticalTabRow(title: tab.title, systemImage: Self.icon(of: tab), help: tab.repoURL?.path ?? tab.title,
                               profileColor: profile?.color, profileName: profile?.name,
                               selected: tab.id == model.selectedTabID, dragged: dragged, namespace: namespace,
                               onSelect: { model.selectTab(id: tab.id) },
                               onClose: { close(tab.id) })
                    .frame(height: SidebarItemStyle.height)
                    .offset(y: offset(of: index, id: tab.id))
                    // Neighbors slide aside; the dragged tab tracks the pointer without lag.
                    .animation(draggedID != nil && !dragged ? animation : nil, value: dragTarget)
                    .zIndex(dragged ? 1 : 0)
                    .gesture(press(tab.id, index: index))
                    .id(tab.id)
            }
        }
        .padding(TabStripMetrics.rowInset)
        // The selected pill slides, also for a selection made elsewhere (a menu, the tab list).
        .animation(animation, value: model.selectedTabID)
    }

    /// The dragged tab follows the pointer; the tabs between its old and new place shift by one row.
    private func offset(of index: Int, id: WindowModel.Tab.ID) -> CGFloat {
        guard let draggedID else { return 0 }
        if id == draggedID { return dragOffset }
        if dragFrom < dragTarget, index > dragFrom, index <= dragTarget { return -step }
        if dragTarget < dragFrom, index >= dragTarget, index < dragFrom { return step }
        return 0
    }

    /// The tab strip's press, vertically: zero distance, so the tab is selected on mouse-down; past
    /// `dragThreshold` it reorders.
    private func press(_ id: WindowModel.Tab.ID, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if pressedID != id {
                    pressedID = id
                    model.selectTab(id: id)
                }
                let translation = value.translation.height
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
                    withAnimation(animation) {
                        dragOffset = 0
                        draggedID = nil
                    }
                } else {
                    draggedID = nil
                    dragOffset = 0
                    model.moveTab(from: dragFrom, to: dragTarget)
                }
            }
    }

    /// The toolbar's repo icon for a repo tab; a missing repo and a Welcome tab get their own.
    private static func icon(of tab: WindowModel.Tab) -> String {
        if tab.isMissing { return "questionmark.folder" }
        return tab.repoURL == nil ? "plus.square.dashed" : "book.closed"
    }

    /// A tab's close button; closing the last tab closes the window, like ⌘W.
    private func close(_ id: WindowModel.Tab.ID) {
        if !model.closeTab(id: id) { model.closeWindow() }
    }
}

/// The selected repo's operation started from a menu, which the tab row shows in the top position.
private struct VerticalTabsStatus: View {
    let model: WindowModel

    var body: some View {
        // No modifiers around it: an idle `RunningStatus` is empty and must take no slot (nor spacing) in the panel.
        if let session = model.selectedSession {
            RunningStatus(session: session)
        }
    }
}

/// One tab as a Settings sidebar row (`SidebarItemStyle`, user 2026-11-13): a 28 pt capsule, 10 pt padding, a 20 pt
/// icon slot then the title (body font), the selected row in `Palette.selectedFill` with a `selectedBorder` edge and
/// full-strength text (the pill slides between rows), the others secondary with a hover capsule. The profile's color is
/// a dot on the icon's corner; the close button replaces the trailing slot on hover.
private struct VerticalTabRow: View {
    let title: String
    let systemImage: String
    let help: String
    /// The profile's `#RRGGBB`; nil without a profile (no dot).
    let profileColor: String?
    let profileName: String?
    let selected: Bool
    let dragged: Bool
    let namespace: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovered && !dragged {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: TabStripMetrics.slot, height: TabStripMetrics.slot)
                }
                .buttonStyle(TabItem.CloseButtonStyle())
                .help("Close Tab")
                .accessibilityLabel("Close \(title)")
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background {
            if selected {
                Capsule()
                    .fill(Palette.selectedFill)
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
        .accessibilityValue(profileName.map { "Profile \($0)" } ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
    }

    /// The tab's icon in the rows' 20 pt slot, with the profile's dot on its lower trailing corner, ringed in the
    /// panel's color so it reads over the glyph.
    private var icon: some View {
        Image(systemName: systemImage)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(width: 20)
            .overlay(alignment: .bottomTrailing) {
                if let profileColor {
                    Circle()
                        .fill(ProfileColors.color(profileColor))
                        .frame(width: TabStripMetrics.dot, height: TabStripMetrics.dot)
                        .overlay(Circle().strokeBorder(Palette.bgCard, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHidden(true)
    }
}
