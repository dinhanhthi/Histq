// The command palette over the window (ported from Dblore's `CommandPaletteView`): a scrim, and a bg_card container
// near the top with its two parts, the search capsule and the results card. It shows in the frame of ⌘K or the click
// that opens it; the rows follow once ranked. Up and Down move the highlight, Return or a click runs the row; Escape or
// a click on the scrim closes it and gives the focus back to the view that had it.
import AppKit
import SwiftUI

@MainActor
enum CommandPaletteMetrics {
    static let width: CGFloat = 560
    static let height: CGFloat = 420
    /// From the top of the content area (under the toolbar).
    static let topMargin: CGFloat = 48
    static let cornerRadius: CGFloat = SettingsMetrics.cardRadius + PanelContainerMetrics.padding
    static let fieldHeight: CGFloat = BottomBarButtonStyle.height
}

/// The window's palette while it is open. Its own view, so only this view reads `WindowModel.palette`: opening the
/// palette never re-evaluates `MainView`.
struct CommandPaletteOverlay: View {
    let model: WindowModel

    var body: some View {
        if let palette = model.palette {
            ZStack(alignment: .top) {
                // The modals' backdrop: this scrim, over the window content `MainView` blurs meanwhile.
                ModalScrim { model.closePalette() }
                CommandPaletteView(model: model, palette: palette)
                    .padding(.top, CommandPaletteMetrics.topMargin)
            }
            // A new view per opening: the highlight, the focus to restore and the timing lines start over.
            .id(ObjectIdentifier(palette))
            // The toolbar stays live above the scrim: a tab or page change (About, ⌘W, the repo menu) closes the
            // palette, whose repo rows act on the session and page it opened on.
            .onChange(of: model.selectedTabID) { model.closePalette() }
            .onChange(of: model.navigation.page) { model.closePalette() }
        }
    }
}

struct CommandPaletteView: View {
    let model: WindowModel
    @Bindable var palette: CommandPaletteModel

    @FocusState private var fieldFocused: Bool
    @State private var selectedID: PaletteItem.ID?
    /// Where the focus was when the palette opened. Restored on Escape or a click on the scrim.
    @State private var previousResponder = WeakResponder()
    @State private var didPerform = false
    @State private var loggedContent = false

    var body: some View {
        PanelContainer(cornerRadius: CommandPaletteMetrics.cornerRadius) {
            VStack(spacing: PanelContainerMetrics.padding) {
                searchField
                results
            }
        }
        .frame(width: CommandPaletteMetrics.width, height: CommandPaletteMetrics.height)
        .shadow(color: Palette.cardShadow, radius: 16, y: 6)
        .onExitCommand { model.closePalette() }
        .onAppear {
            UITiming.placeholder("palette")
            if let responder = NSApp.keyWindow?.firstResponder as? NSView,
               !((responder as? NSTextView)?.isFieldEditor ?? false)
            {
                previousResponder.view = responder
            }
            // The overlay is installed on this turn. Focus the field on the next one.
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onDisappear {
            guard !didPerform, let view = previousResponder.view else { return }
            // Escape releases the field editor on its own turn. Restore after it.
            DispatchQueue.main.async {
                guard let window = view.window, window.isKeyWindow else { return }
                window.makeFirstResponder(view)
            }
        }
        .onChange(of: palette.ranked) { _, ranked in
            selectedID = ranked.first?.id
        }
        .onChange(of: palette.isRankFresh) { _, fresh in
            guard fresh, !loggedContent else { return }
            loggedContent = true
            UITiming.content("palette \(palette.ranked.count)")
        }
    }

    // MARK: Parts

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $palette.query, prompt: Text("Search commands, branches, tabs"))
                .textFieldStyle(.plain)
                .labelsHidden()
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape]) { press in
                    handleKey(press)
                }
            if !palette.query.isEmpty {
                Button {
                    palette.query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: CommandPaletteMetrics.fieldHeight)
        .background(Capsule().fill(Palette.inputSurface))
        .overlay(Capsule().strokeBorder(Palette.surfaceBorder, lineWidth: 1))
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if palette.showsNoMatches {
                    Text("No matching commands")
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    // Not lazy: at most 50 rows, and `scrollTo` lands short on rows a lazy stack has not laid out.
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.settingsCaption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 6)
                                .padding(.bottom, 2)
                            ForEach(section.items) { item in
                                CommandPaletteRow(item: item, isSelected: item.id == activeID) { activate(item) }
                                    .id(item.id)
                            }
                        }
                    }
                    .padding(PanelContainerMetrics.padding)
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
        .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
    }

    // MARK: Selection

    /// Consecutive rows of one section under one header, in score order: a section can show twice when a better row
    /// of another section sits between. Keyboard order is the same list.
    private var sections: [CommandPaletteGroup] {
        var groups: [CommandPaletteGroup] = []
        for item in palette.ranked {
            if let last = groups.last, last.section == item.section {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(CommandPaletteGroup(id: "\(item.section.rawValue)-\(groups.count)", section: item.section,
                                                  items: [item]))
            }
        }
        return groups
    }

    /// The highlighted row. `selectedID` is reset in `onChange`, one render after the rows change, so an id that left
    /// the list falls back to the first row in the same pass.
    private var activeID: PaletteItem.ID? {
        let items = palette.ranked
        if let selectedID, items.contains(where: { $0.id == selectedID }) { return selectedID }
        return items.first?.id
    }

    /// Up, Down, Return and Escape; ⌘K stays with the File menu.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Return commits an IME syllable: it must not run the highlighted row.
        if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return .ignored }
        guard press.modifiers.intersection([.command, .shift, .option, .control]).isEmpty else { return .ignored }
        switch press.key {
        case .upArrow: moveSelection(by: -1)
        case .downArrow: moveSelection(by: 1)
        case .escape: model.closePalette()
        case .return:
            guard press.phase == .down else { return .handled }
            if let activeID, let item = palette.ranked.first(where: { $0.id == activeID }) { activate(item) }
        default: return .ignored
        }
        return .handled
    }

    private func moveSelection(by delta: Int) {
        let items = palette.ranked
        guard !items.isEmpty else { return }
        guard let activeID, let index = items.firstIndex(where: { $0.id == activeID }) else {
            selectedID = items[0].id
            return
        }
        selectedID = items[min(max(index + delta, 0), items.count - 1)].id
    }

    /// Return and a click both refuse a disabled row or one left over from an older query.
    private func activate(_ item: PaletteItem) {
        didPerform = true
        if !model.performPalette(item) { didPerform = false }
    }
}

/// Weak, so a closed tab's view is not kept alive by the palette.
private final class WeakResponder {
    weak var view: NSView?
}

private struct CommandPaletteGroup: Identifiable {
    let id: String
    let section: PaletteSection
    var items: [PaletteItem]

    var title: String { section.rawValue }
}

/// One row: the sidebar's capsule row (hover, pressed, the selected highlight), its icon and title, the detail at the
/// trailing edge. A disabled row is dimmed.
private struct CommandPaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 8) {
                Label(item.title, systemImage: item.systemImage)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(item.detail)
                    .font(.settingsCaption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(SidebarItemStyle(selected: isSelected))
        .opacity(item.isEnabled ? 1 : 0.45)
        .help(item.isEnabled ? item.title : "\(item.title) (unavailable now)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
