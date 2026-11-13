// The Settings page, sidebar layout: the sections in a raised card, the selected one's cards on the right over the
// window's glass; each change is saved at once.
import SwiftUI

/// The Settings page `MainView` shows; the tab layout defines the same name.
typealias SettingsRoot = SettingsSidebarView

/// A sidebar section. Adding one: a case (its raw value is the `-HistqSelect settings:<section>` value), its row in
/// `label`, its page in `SettingsSidebarView.content`.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, profiles, ssh

    var id: Self { self }

    var label: (title: String, icon: String) {
        switch self {
        case .general: ("General", "gearshape")
        case .appearance: ("Appearance", "paintbrush")
        case .profiles: ("Profiles", "person.crop.circle")
        case .ssh: ("SSH", "key")
        }
    }
}

struct SettingsSidebarView: View {
    @Environment(WindowModel.self) private var model
    /// Sections opened so far: kept alive like TabView's tabs, so a section keeps its state (and its scroll) when
    /// the user comes back to it.
    @State private var opened: Set<SettingsSection> = []
    /// The profile the Profiles and SSH pages edit, shared so both show the same one.
    @State private var profileID: UUID?
    @FocusState private var sidebarFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The profile whose "Generate Key" modal is open. Every modal's flag goes into `modalOpen`.
    @State private var generatingFor: UUID?
    /// The page's width, for the modal's card.
    @State private var containerWidth: CGFloat = 0
    /// The page's blur behind an open modal, animated alone in `onChange(of: modalOpen)`.
    @State private var backdropBlur: CGFloat = 0

    private var section: SettingsSection { model.settingsSection }
    private var modalOpen: Bool { generatingFor != nil }

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 0) {
                sidebar
                ZStack {
                    // The selected section is mounted in the same update as the click, before `opened` records it.
                    ForEach(SettingsSection.allCases.filter { opened.contains($0) || $0 == section }) { page in
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

            // It fills this page, under the toolbar's band (see window-toolbar.md, Modal).
            SettingsModal(isPresented: modalOpen, containerWidth: containerWidth, dismissOnBackdropTap: false,
                          onDismiss: { generatingFor = nil }) {
                if let id = generatingFor {
                    GenerateKeyModal(profileID: id) { withAnimation(Motion.sheet) { generatingFor = nil } }
                }
            }
        }
        // Esc before the card's own focus lands still closes the open modal.
        .onExitCommand {
            guard modalOpen else { return }
            withAnimation(Motion.sheet) { generatingFor = nil }
        }
        .onAppear {
            sidebarFocused = true
            ProfileLibrary.shared.loadIfNeeded()
        }
        .onChange(of: section, initial: true) { _, new in opened.insert(new) }
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
            SSHSettings(profileID: $profileID, onShowProfiles: { model.selectSettings(.profiles) }) { id in
                withAnimation(Motion.sheet) { generatingFor = id }
            }
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
        model.navigation.page == .settings && model.settingsSection == section
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
