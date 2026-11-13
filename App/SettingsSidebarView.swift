// The Settings page, sidebar layout: the sections in a raised card, the selected one's cards on the right over the
// window's glass; each change is saved at once.
import AppKit
import SwiftUI

/// The Settings page `MainView` shows; the tab layout defines the same name.
typealias SettingsRoot = SettingsSidebarView

/// A sidebar section. Adding one: a case, its row in `label`, its page in `SettingsSidebarView.content`.
private enum SettingsSection: CaseIterable, Identifiable {
    case appearance, general, advanced

    var id: Self { self }

    var label: (title: String, icon: String) {
        switch self {
        case .appearance: ("Appearance", "paintbrush")
        case .general: ("General", "gearshape")
        case .advanced: ("Advanced", "wrench.and.screwdriver")
        }
    }
}

struct SettingsSidebarView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.defaultMode
    // Sample settings: replace them with the app's own.
    @AppStorage("ShowPreviews") private var showPreviews = true
    @AppStorage("ConfirmDelete") private var confirmDelete = true
    @AppStorage("DisplayName") private var displayName = ""
    @AppStorage("VerboseLogging") private var verboseLogging = false
    @State private var advancedExpanded = false
    @State private var section = SettingsSection.appearance
    /// Sections opened so far: kept alive like TabView's tabs, so a section keeps its state (and its scroll) when
    /// the user comes back to it.
    @State private var opened: Set<SettingsSection> = []
    @FocusState private var sidebarFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The sample modal. Every modal's flag goes into `modalOpen`.
    @State private var showingDetails = false
    /// The page's width, for the modal's card.
    @State private var containerWidth: CGFloat = 0
    /// The page's blur behind an open modal, animated alone in `onChange(of: modalOpen)`.
    @State private var backdropBlur: CGFloat = 0

    private var modalOpen: Bool { showingDetails }

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 0) {
                sidebar
                ZStack {
                    ForEach(SettingsSection.allCases.filter(opened.contains)) { page in
                        let selected = page == section
                        ScrollView {
                            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                                content(page)
                            }
                            // No top padding: the page's first element is top-aligned with the sidebar card. 12 pt
                            // from the card's trailing edge.
                            .padding(.leading, SettingsMetrics.sidebarInset)
                            .padding([.trailing, .bottom], SettingsMetrics.pagePadding)
                        }
                        .labeledContentStyle(.settingsRow)
                        .opacity(selected ? 1 : 0)
                        // The leaving section fades out faster, so the two never show through each other.
                        .animation(switchAnimation(selected: selected), value: selected)
                        .allowsHitTesting(selected)
                        .disabled(!selected)
                        .accessibilityHidden(!selected)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Behind an open modal the page leaves the key-view loop and the accessibility tree, and blurs lightly
            // (still faintly readable under the scrim).
            .disabled(modalOpen)
            .accessibilityHidden(modalOpen)
            .blur(radius: backdropBlur, opaque: false)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { containerWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in containerWidth = width }
                }
            }

            // Sample modal: replace it with the app's own. It fills this page, under the toolbar's band (see
            // window-toolbar.md, Modal).
            SettingsModal(isPresented: showingDetails, containerWidth: containerWidth,
                          onDismiss: { showingDetails = false }) {
                DetailsModalContent { withAnimation(Motion.sheet) { showingDetails = false } }
            }
        }
        // Esc before the card's own focus lands still closes the open modal.
        .onExitCommand {
            guard modalOpen else { return }
            withAnimation(Motion.sheet) { showingDetails = false }
        }
        .onAppear { sidebarFocused = true }
        .onChange(of: section, initial: true) { _, new in opened.insert(new) }
        .onChange(of: appearance) { _, mode in mode.apply() }
        .onChange(of: modalOpen) { _, open in
            // The sidebar was disabled behind the modal: take the focus back on the next turn.
            if !open { DispatchQueue.main.async { sidebarFocused = true } }
            // A fade, not movement: animated under Reduce Motion too.
            withAnimation(open ? Motion.sheet : Motion.exit) {
                backdropBlur = open ? SettingsModalBackdrop.blurRadius : 0
            }
        }
    }

    /// Capsule rows with a gap between them in a raised card, not a `List(.sidebar)`: its selection fills the whole
    /// row, so the rows touch. Up/Down move the selection while the card has the focus.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: SidebarItemStyle.spacing) {
            ForEach(SettingsSection.allCases) { row in
                Button {
                    section = row
                    sidebarFocused = true
                } label: {
                    Label(row.label.title, systemImage: row.label.icon)
                }
                .buttonStyle(SidebarItemStyle(selected: row == section))
                .accessibilityAddTraits(row == section ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(SettingsMetrics.sidebarRowsPadding)
        .frame(width: SettingsMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($sidebarFocused)
        .onMoveCommand(perform: moveSelection)
        // A raised card like the toolbar's capsules, instead of a divider beside the sections.
        .modifier(GlassCard(cornerRadius: SettingsMetrics.sidebarRadius, raised: true))
        // At the top of the safe area: about 8 pt under the toolbar's capsules. The page starts at the same top edge.
        .padding([.leading, .bottom], SettingsMetrics.sidebarInset)
    }

    /// Up/Down in the sidebar: the previous or next section, stopping at the ends.
    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !modalOpen else { return }
        let all = SettingsSection.allCases
        guard let index = all.firstIndex(of: section) else { return }
        switch direction {
        case .up where index > all.startIndex: section = all[index - 1]
        case .down where index < all.count - 1: section = all[index + 1]
        default: break
        }
    }

    /// A fade between sections; an instant switch under Reduce Motion.
    private func switchAnimation(selected: Bool) -> Animation? {
        if reduceMotion { return nil }
        return selected ? Motion.standard : Motion.exit
    }

    @ViewBuilder
    private func content(_ section: SettingsSection) -> some View {
        switch section {
        case .appearance:
            SettingsGroup("Appearance") {
                LabeledContent("Theme") {
                    CapsuleTabs(selection: $appearance, tabs: AppearanceMode.allCases,
                                title: { Text($0.title) }, compact: true)
                        .fixedSize()
                }
            }
        case .general:
            SettingsGroup("General", description: "Each change is saved at once.") {
                switchRow(isOn: $showPreviews, title: "Show previews",
                          hint: "Shows a preview of each item in the list.")
                SettingsDivider()
                switchRow(isOn: $confirmDelete, title: "Confirm before deleting", hint: nil)
                SettingsDivider()
                LabeledContent {
                    TextField("Name", text: $displayName, prompt: Text("Your name"))
                        .textFieldStyle(.settings)
                        .frame(maxWidth: 220)
                        .labelsHidden()
                } label: {
                    Text("Display name")
                    hint("Shown in the window's title.")
                }
                SettingsDivider()
                LabeledContent {
                    Button("Reveal in Finder", action: revealInFinder)
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                } label: {
                    Text("App")
                    hint("Shows the app in a Finder window.")
                }
            }
        case .advanced:
            SettingsGroup("Advanced") {
                DisclosureGroup(isExpanded: $advancedExpanded) {
                    switchRow(isOn: $verboseLogging, title: "Verbose logging",
                              hint: "Writes more detail to the system log.")
                        .padding(.leading, TitleChevronDisclosureStyle.indent)
                        .padding(.top, 6)
                } label: {
                    Text("Diagnostics")
                    hint("Options for tracking down a problem.")
                }
                .disclosureGroupStyle(TitleChevronDisclosureStyle())
                SettingsDivider()
                LabeledContent {
                    Button("Show Details") { withAnimation(Motion.sheet) { showingDetails = true } }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                } label: {
                    Text("Details")
                    hint("Opens a modal over the page.")
                }
            }
        }
    }

    /// A row with a title, an optional hint under it, and a `CompactSwitch` (which draws no label of its own).
    private func switchRow(isOn: Binding<Bool>, title: String, hint: String?) -> some View {
        LabeledContent {
            Toggle(title, isOn: isOn)
                .toggleStyle(CompactSwitch())
                .labelsHidden()
        } label: {
            Text(title)
            if let hint { self.hint(hint) }
        }
    }

    /// The hint under a row's title.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.settingsCaption)
            .foregroundStyle(.secondary)
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}

/// Sample modal content: a header at the top of the card, a divider, and a scrolling body. Replace it.
private struct DetailsModalContent: View {
    let onClose: () -> Void
    /// The card holds the focus while it is open (it has no field), so Esc reaches the modal.
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Details")
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 0)
                Button("Done", action: onClose)
                    .buttonStyle(BottomBarButtonStyle(height: 28, prominent: true, horizontalPadding: 12))
            }
            // Symmetric vertical padding at the top of the card.
            .padding(.horizontal, SettingsMetrics.cardPadding)
            .padding(.vertical, SettingsMetrics.cardPadding + 6)
            Divider()
            ScrollView {
                Text("The modal sets the card's height; this body scrolls inside it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SettingsMetrics.pagePadding)
            }
        }
        // No minimum height: the modal sets it.
        .frame(minWidth: 480)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // Next run-loop turn, once the card is in the window.
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
