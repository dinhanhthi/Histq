// Settings, a modal over the window (task 9.7, `ModalHost`): a header card with the title and a close button, then
// the sections in a card and the selected one's cards on the right; each change is saved at once.
import SwiftUI

enum SettingsModalMetrics {
    /// The card's widest: past it the rows' titles and their controls drift too far apart to read as one row.
    static let maxWidth: CGFloat = 980
}

/// The Settings modal's card, decorated like every modal (`ModalCard`: the palette's container and shadow). It fills
/// the space `ModalHost` gives it, up to `SettingsModalMetrics.maxWidth`: one size for every section, so switching
/// never resizes it.
struct SettingsModal: View {
    let onClose: () -> Void

    var body: some View {
        PanelContainer(cornerRadius: ModalMetrics.cornerRadius) {
            VStack(spacing: PanelContainerMetrics.padding) {
                header
                SettingsSidebarView()
            }
        }
        .frame(maxWidth: SettingsModalMetrics.maxWidth, maxHeight: .infinity)
        .shadow(color: Palette.cardShadow, radius: 16, y: 6)
    }

    /// `ModalCard`'s header (plain text on the container, no card), with the close button at the trailing edge.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Settings")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(RowIconButtonStyle())
            .help("Close Settings (Esc)")
            .accessibilityLabel("Close Settings")
            .padding(.trailing, 4)
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A sidebar section. Adding one: a case (its raw value is the `-HistqSelect settings:<section>` value), its row in
/// `label`, its page in `SettingsSidebarView.content`.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, profiles, ssh, integrations, ai

    var id: Self { self }

    var label: (title: String, icon: String) {
        switch self {
        case .general: ("General", "gearshape")
        case .appearance: ("Appearance", "paintbrush")
        case .profiles: ("Profiles", "person.crop.circle")
        case .ssh: ("SSH", "key")
        case .integrations: ("Integrations", "link")
        case .ai: ("AI", "sparkles")
        }
    }
}

struct SettingsSidebarView: View {
    @Environment(WindowModel.self) private var model
    /// Sections whose page is built: kept alive like TabView's tabs, so a section keeps its state (and its scroll)
    /// when the user comes back to it. A section joins just after its first select (`onChange(of: section)`).
    @State private var opened: Set<SettingsSection> = []
    /// The profile the Profiles, SSH and Integrations pages edit, shared so all show the same one.
    @State private var profileID: UUID?
    @FocusState private var sidebarFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var section: SettingsSection { model.settingsSection }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            ZStack {
                // A section not built yet shows its skeleton in the click's frame: building a page (20-30 ms the
                // first time, more with the modal) would hold that frame past 16 ms.
                if !opened.contains(section) {
                    page {
                        SettingsPageGate(section: section, isLoaded: false) {
                            EmptyView()
                        } skeleton: {
                            SettingsSkeletonGroup(rows: 3)
                            SettingsSkeletonGroup()
                        }
                    }
                    .id(section)
                }
                ForEach(SettingsSection.allCases.filter(opened.contains)) { built in
                    let selected = built == section
                    page { content(built) }
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
        .onAppear {
            // The modal is installed on this turn; the sidebar takes the focus on the next one, after `ModalHost`
            // noted the view to give it back to.
            DispatchQueue.main.async { sidebarFocused = true }
            ProfileLibrary.shared.loadIfNeeded()
        }
        .onChange(of: section, initial: true) { _, new in
            guard !opened.contains(new) else { return }
            // A timer, not the next main-queue turn: AppKit runs a queued block before it draws, so the skeleton
            // frame would never reach the screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { opened.insert(new) }
        }
        .onChange(of: model.modal == nil) { _, closed in
            // The sidebar was disabled behind the modal: take the focus back on the next turn.
            if closed { DispatchQueue.main.async { sidebarFocused = true } }
        }
    }

    /// A section's scrolling column of cards.
    private func page(@ViewBuilder _ cards: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                cards()
            }
            // No top padding: the page's first element is top-aligned with the sidebar card. 12 pt from the card's
            // trailing edge; the cards end where the header card does.
            .padding(.leading, SettingsMetrics.sidebarInset)
            .padding(.bottom, SettingsMetrics.sidebarInset)
        }
        .labeledContentStyle(.settingsRow)
    }

    /// Capsule rows with a gap between them in a card of the modal, not a `List(.sidebar)`: its selection fills the
    /// whole row, so the rows touch. Up/Down move the selection while the card has the focus.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: SidebarItemStyle.spacing) {
            ForEach(SettingsSection.allCases) { row in
                Button {
                    if row != section { model.selectSettings(row) }
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
        // A card of the modal (concentric with its container), instead of a divider beside the sections. The page
        // starts at the same top edge.
        .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
    }

    /// Up/Down in the sidebar: the previous or next section, stopping at the ends.
    private func moveSelection(_ direction: MoveCommandDirection) {
        let all = SettingsSection.allCases
        guard let index = all.firstIndex(of: section) else { return }
        switch direction {
        case .up where index > all.startIndex: model.selectSettings(all[index - 1])
        case .down where index < all.count - 1: model.selectSettings(all[index + 1])
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
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .profiles: ProfilesSettings(profileID: $profileID)
        case .ssh:
            // Above the Settings modal (`ModalHost`), which is blurred and disabled behind it.
            SSHSettings(profileID: $profileID, onShowProfiles: { model.selectSettings(.profiles) }) { id in
                model.presentModal(.generateKey(profileID: id))
            }
        case .integrations:
            IntegrationsSettings(profileID: $profileID, onShowProfiles: { model.selectSettings(.profiles) })
        case .ai: AISettings()
        }
    }
}

/// A settings section's loading state and timing lines: once `isLoaded`, the content, logging
/// `content settings <section>` when it shows and at each select of the section; before, `skeleton` (capsule bars in
/// the content's layout) with a delayed spinner, logging `placeholder settings <section>`. Hidden sections (kept alive
/// behind the selected one) log nothing.
struct SettingsPageGate<Content: View, Skeleton: View>: View {
    let section: SettingsSection
    let isLoaded: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let skeleton: () -> Skeleton
    @Environment(WindowModel.self) private var model

    private var detail: String { "settings \(section.rawValue)" }

    private var isSelected: Bool {
        model.isSettingsOpen && model.settingsSection == section
    }

    var body: some View {
        if isLoaded {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                content()
            }
            .onChange(of: model.settingsToken, initial: true) {
                if isSelected { UITiming.content(detail) }
            }
        } else {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                skeleton()
            }
            .allowsHitTesting(false)
            .overlay { DelayedSpinner(detail: detail, isCurrent: { isSelected }) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
            .onChange(of: model.settingsToken, initial: true) {
                if isSelected { UITiming.placeholder(detail) }
            }
        }
    }
}

/// A skeleton settings card: a title bar, then `rows` rows of a title bar and a control bar, in a `SettingsGroup`'s
/// shape.
struct SettingsSkeletonGroup: View {
    var rows = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonLine(width: 90, height: 13)
                .padding(.horizontal, SettingsMetrics.cardPadding)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<rows, id: \.self) { row in
                    if row > 0 { SettingsDivider() }
                    HStack {
                        SkeletonLine(width: 140 - CGFloat(row % 3) * 24, height: 12)
                        Spacer(minLength: 12)
                        SkeletonLine(width: 110, height: 20)
                    }
                    .frame(minHeight: 24)
                }
            }
            .padding(.horizontal, SettingsMetrics.cardPadding)
            .padding(.vertical, SettingsMetrics.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
        }
    }
}

/// A row with a title, an optional hint under it, and a `CompactSwitch` (which draws no label of its own).
struct SettingsSwitchRow: View {
    let title: String
    var hint: String?
    @Binding var isOn: Bool

    var body: some View {
        LabeledContent {
            Toggle(title, isOn: $isOn)
                .toggleStyle(CompactSwitch())
                .labelsHidden()
        } label: {
            Text(title)
            if let hint { SettingsHint(hint) }
        }
    }
}

/// The hint under a row's title.
struct SettingsHint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.settingsCaption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
