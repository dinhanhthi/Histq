// The window's look: adaptive dark/light colors, motion, cards, the window glass and small controls.
import AppKit
import SwiftUI

/// The single place for macOS 26 feature gates. Call sites still need `if #available(macOS 26, *)` for the
/// compiler; this adds the DEBUG `--force-fallbacks` override on top, so pre-26 paths can be checked on 26+.
enum PlatformFeatures {
    static let forceFallbacks: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--force-fallbacks")
        #else
        return false
        #endif
    }()

    static var liquidGlass: Bool {
        if #available(macOS 26, *) { return !forceFallbacks }
        return false
    }
}

/// The app colors. Each one has a dark and a light value and follows the window's appearance live.
enum Palette {
    /// The tint over the window's blur (`WindowGlass`). #1C1C1E / #F5F5F7, both at 0.6.
    static let windowTint = dynamicNSColor(
        dark: NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.6),
        light: NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 0.6))
    static let hoverFill = dynamic(dark: .white.withAlphaComponent(0.1), light: .black.withAlphaComponent(0.06))
    static let pressedFill = dynamic(dark: .white.withAlphaComponent(0.2), light: .black.withAlphaComponent(0.12))
    /// The selected sidebar row's capsule and its 1 pt edge: neutral, no accent.
    static let selectedFill = dynamic(dark: .white.withAlphaComponent(0.14), light: .black.withAlphaComponent(0.07))
    static let selectedBorder = dynamic(dark: .white.withAlphaComponent(0.12), light: .black.withAlphaComponent(0.08))
    /// Darkens a pressed button over its own fill.
    static let pressedOverlay = dynamic(dark: .black.withAlphaComponent(0.2), light: .black.withAlphaComponent(0.1))
    /// Dims the window behind an in-window modal (`SettingsModal`), over the page's light backdrop blur.
    static let scrim = dynamic(dark: .black.withAlphaComponent(0.45), light: .black.withAlphaComponent(0.28))
    /// Text and glyphs on the gold accent fill (white on gold is ~1.7:1). #1C1C1E / #1D1D1F
    static let onAccent = dynamic(
        dark: NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1),
        light: NSColor(srgbRed: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1))
    static let switchOffFill = dynamic(dark: .white.withAlphaComponent(0.22), light: .black.withAlphaComponent(0.15))
    /// The shadow of the switch's white knob, the same in both modes.
    static let knobShadow = Color.black.opacity(0.2)
    /// Cards and panels, a step above the window. #2C2C2E / #FFFFFF
    static let surface = dynamic(
        dark: NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1),
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    /// Controls on a card, a step above `surface`. #3A3A3C / #EBEBED
    static let inputSurface = dynamic(
        dark: NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 60 / 255, alpha: 1),
        light: NSColor(srgbRed: 235 / 255, green: 235 / 255, blue: 237 / 255, alpha: 1))
    /// The 1 pt edge of cards and panels.
    static let surfaceBorder = dynamic(dark: .white.withAlphaComponent(0.08), light: .black.withAlphaComponent(0.08))
    /// The edge of a raised card: bright at the top, dim on the sides, a faint highlight at the bottom.
    static let raisedRim = LinearGradient(
        stops: [
            .init(color: dynamic(dark: .white.withAlphaComponent(0.24), light: .black.withAlphaComponent(0.10)),
                  location: 0),
            .init(color: dynamic(dark: .white.withAlphaComponent(0.05), light: .black.withAlphaComponent(0.05)),
                  location: 0.45),
            .init(color: dynamic(dark: .white.withAlphaComponent(0.10), light: .black.withAlphaComponent(0.12)),
                  location: 1),
        ],
        startPoint: .top, endPoint: .bottom)
    /// The light at the top of a raised button's fallback capsule.
    static let buttonSheen = LinearGradient(
        colors: [dynamic(dark: .white.withAlphaComponent(0.08), light: .white.withAlphaComponent(0.6)), .clear],
        startPoint: .top, endPoint: .center)
    /// The light at the top of a raised card; none in light mode.
    static let cardSheen = LinearGradient(
        colors: [dynamic(dark: .white.withAlphaComponent(0.05), light: .clear), .clear],
        startPoint: .top, endPoint: .center)
    /// The shadow under a raised card (radius 6, y 3).
    static let cardShadow = dynamic(dark: .black.withAlphaComponent(0.35), light: .black.withAlphaComponent(0.10))
    /// The shadow under a raised button's fallback capsule (radius 3, y 1.5).
    static let buttonShadow = dynamic(dark: .black.withAlphaComponent(0.35), light: .black.withAlphaComponent(0.12))

    /// A color that resolves to `dark` under a dark appearance and to `light` otherwise.
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: dynamicNSColor(dark: dark, light: light))
    }

    private static func dynamicNSColor(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}

/// The app's shared animations.
enum Motion {
    /// Pages, tabs, panels, lists and the pill: a quick spring, its small bounce invisible at this length.
    static let standard = Animation.snappy(duration: 0.25)
    /// Hover highlights.
    static let hover = Animation.easeOut(duration: 0.12)
    /// Sheets and the search bar opening: a touch slower than `standard`.
    static let sheet = Animation.snappy(duration: 0.3)
    /// A view leaving: a short fade, quicker than its entrance.
    static let exit = Animation.easeOut(duration: 0.1)
    /// A button going down and back up.
    static let press = Animation.snappy(duration: 0.12)
    /// Switches and disclosure chevrons.
    static let toggle = Animation.snappy(duration: 0.2)
}

/// A raised button like the toolbar's: `height` tall (a circle for an icon, with no `horizontalPadding`). Liquid Glass
/// on macOS 26; before, a capsule lit from above with a soft shadow, like `GlassCard(raised:)`. Lighter on hover,
/// darker while pressed, dimmed when disabled. `tint` colors the glass (or the capsule's fill).
struct RaisedButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var horizontalPadding: CGFloat = 0
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Raised(configuration: configuration, height: height, horizontalPadding: horizontalPadding, tint: tint)
    }

    private struct Raised: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let horizontalPadding: CGFloat
        let tint: Color?
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let fill = configuration.isPressed ? Palette.pressedOverlay : hovered && isEnabled ? Palette.hoverFill : .clear
            configuration.label
                .foregroundStyle(.primary)
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: height, minHeight: height, maxHeight: height)
                .modifier(RaisedCapsule(tint: tint))
                .overlay(Capsule().fill(fill).allowsHitTesting(false))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }

    private struct RaisedCapsule: ViewModifier {
        let tint: Color?

        func body(content: Content) -> some View {
            if #available(macOS 26, *), PlatformFeatures.liquidGlass {
                content.glassEffect(.regular.tint(tint), in: Capsule())
            } else {
                content
                    .background {
                        Capsule().fill(tint ?? Palette.inputSurface)
                            .overlay(Capsule().fill(Palette.buttonSheen))
                            .shadow(color: Palette.buttonShadow, radius: 3, y: 1.5)
                    }
                    .overlay(Capsule().strokeBorder(Palette.raisedRim, lineWidth: 1).allowsHitTesting(false))
            }
        }
    }
}

/// A small text button of a card row: a capsule of the input color, lighter on hover, darker while pressed.
/// `formRow`: as tall as a compact `CapsuleTabs`, for a form row. `prominent`: the accent color with white text.
struct RowTextButtonStyle: ButtonStyle {
    var formRow = false
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, formRow: formRow, prominent: prominent)
    }

    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        let formRow: Bool
        let prominent: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(formRow ? .body : .callout.weight(.medium))
                .foregroundStyle(prominent ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.primary))
                .padding(.horizontal, formRow ? 12 : 8)
                .padding(.vertical, formRow ? 0 : 4)
                .frame(height: formRow ? 24 : nil)
                .background(
                    Capsule()
                        .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Palette.inputSurface))
                        .overlay(Capsule().fill(
                            configuration.isPressed ? Palette.pressedOverlay : hovered && isEnabled ? Palette.hoverFill : .clear)))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// The icon buttons of a row: a round highlight on hover, darker and a bit smaller while pressed, dimmed when
/// disabled. The highlight reaches past the label without changing the row's layout.
struct RowIconButtonStyle: ButtonStyle {
    /// A capsule highlight, for a label wider than an icon (an icon and a menu chevron).
    var capsule = false

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, capsule: capsule)
    }

    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        let capsule: Bool
        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let fill = configuration.isPressed ? Palette.pressedFill : hovered && isEnabled ? Palette.hoverFill : .clear
            configuration.label
                .background {
                    if capsule {
                        Capsule().fill(fill).padding(-5)
                    } else {
                        Circle().fill(fill).padding(-5)
                    }
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
                .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// A row of a settings sidebar: the selected row is a neutral capsule (`Palette.selectedFill`) with a 1 pt
/// `Palette.selectedBorder` edge and full-strength title and icon; the others have secondary title and icon and get a
/// hover capsule (in light mode also full-strength title and icon, as secondary text is faint on the hover fill). Rows sit in a `VStack(spacing: SidebarItemStyle.spacing)` instead of a `List(.sidebar)`, whose
/// selection fills the whole row height, so neighbors touch however much padding the rows get.
struct SidebarItemStyle: ButtonStyle {
    var selected: Bool
    /// Gap between two rows' capsules.
    static let spacing: CGFloat = 6
    /// Height of a row's capsule (a body line with 6 pt above and below); a taller label grows it.
    static let height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovered = false
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let fill: Color = selected ? Palette.selectedFill
                : configuration.isPressed ? Palette.pressedFill
                : hovered ? Palette.hoverFill : .clear
            configuration.label
                .labelStyle(SidebarLabelStyle(emphasized: selected || hovered && colorScheme == .light))
                .padding(.horizontal, 10)
                .frame(minHeight: SidebarItemStyle.height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(selected ? Palette.selectedBorder : .clear, lineWidth: 1))
                .contentShape(Capsule())
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }

    private struct SidebarLabelStyle: LabelStyle {
        /// Full-strength text: the selected row, or a hovered one in light mode.
        let emphasized: Bool

        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 8) {
                configuration.icon
                    .frame(width: 20)
                    .foregroundStyle(emphasized ? Color.primary : Color.secondary)
                configuration.title
                    .foregroundStyle(emphasized ? Color.primary : Color.secondary)
            }
        }
    }
}

/// A button of a bottom bar: `height` tall (a circle for an icon, with no `horizontalPadding`), a capsule of the input
/// color, or the accent color when `prominent`; lighter on hover, darker while pressed, dimmed when disabled.
struct BottomBarButtonStyle: ButtonStyle {
    /// Every control of the bottom bars: buttons, menus, chips and a one-line text field.
    static let height: CGFloat = 34

    var height = Self.height
    var prominent = false
    var horizontalPadding: CGFloat = 14
    /// A menu's trigger: it stays pressed while its menu is open, and shows the hover look then, not the darker one.
    var menu = false

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, height: height, prominent: prominent,
                  horizontalPadding: horizontalPadding, menu: menu)
    }

    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let prominent: Bool
        let horizontalPadding: CGFloat
        let menu: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.primary))
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: height, minHeight: height, maxHeight: height)
                .background(
                    Capsule()
                        .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Palette.inputSurface))
                        .overlay(Capsule().fill(
                            configuration.isPressed && !menu ? Palette.pressedOverlay
                                : (hovered || configuration.isPressed) && isEnabled ? Palette.hoverFill : .clear)))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// A toolbar button alone in its capsule: on macOS 26 AppKit gives it no hover highlight (only buttons of a group get
/// one), so it draws the same small round highlight itself. `help` is its tooltip and accessibility label.
struct ToolbarIconButton: View {
    let systemImage: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        if #available(macOS 26, *) {
            Button(action: action) {
                label
                    .labelStyle(.iconOnly)
                    .font(.body)
                    .imageScale(.large)
            }
            .buttonStyle(Highlight())
            .help(help)
        } else {
            Button(action: action) { label }
                .help(help)
        }
    }

    private var label: some View {
        Label {
            Text(help)
        } icon: {
            Image(systemName: systemImage)
        }
    }

    /// AppKit pads the item less on the sides than above and below: 36 by 24 makes the capsule round. The highlight
    /// is as big as a group button's.
    private struct Highlight: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            HoverCircle(configuration: configuration)
        }

        private struct HoverCircle: View {
            let configuration: ButtonStyleConfiguration
            @State private var hovered = false

            var body: some View {
                configuration.label
                    .frame(width: 36, height: 24)
                    .background {
                        Circle()
                            .fill(configuration.isPressed ? Palette.pressedFill : hovered ? Palette.hoverFill : .clear)
                            .frame(width: 28, height: 28)
                    }
                    .contentShape(Rectangle())
                    .animation(Motion.hover, value: hovered)
                    .onHover { hovered = $0 }
            }
        }
    }
}

/// The arrow of a menu button.
struct MenuChevron: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .accessibilityHidden(true)
    }
}

/// Tabs for a toolbar item, as tall as its buttons' highlights, in the toolbar's capsule on macOS 26 (a surface capsule
/// before): the selected tab is an accent capsule that slides between the tabs (no slide under Reduce Motion).
/// `compact`: smaller, always on a surface capsule, for a form row.
struct CapsuleTabs<Tab: Hashable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: (Tab) -> Text
    var compact = false
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                Item(tab: tab, title: title(tab), selected: tab == selection, compact: compact, namespace: namespace) {
                    withAnimation(animation) { selection = tab }
                }
            }
        }
        // One pill that follows the selected item's frame, so it slides instead of fading between items.
        .background {
            Capsule()
                .fill(Color.accentColor)
                .matchedGeometryEffect(id: selection, in: namespace, isSource: false)
        }
        // Also animates a selection set from code (menus, shortcuts).
        .animation(animation, value: selection)
        .modifier(SurfaceTrack(compact: compact))
    }

    private var animation: Animation? { reduceMotion ? nil : Motion.standard }

    /// Before macOS 26 the toolbar draws no capsule around its items; a form never does.
    private struct SurfaceTrack: ViewModifier {
        let compact: Bool

        func body(content: Content) -> some View {
            if #available(macOS 26, *), PlatformFeatures.liquidGlass, !compact {
                content
            } else {
                content
                    .padding(compact ? 2 : 3)
                    .background(Capsule().fill(Palette.surface))
                    .overlay(Capsule().strokeBorder(Palette.surfaceBorder, lineWidth: 1).allowsHitTesting(false))
            }
        }
    }

    private struct Item: View {
        let tab: Tab
        let title: Text
        let selected: Bool
        let compact: Bool
        let namespace: Namespace.ID
        let action: () -> Void
        @State private var hovered = false
        /// A toolbar button's highlight; a form row's control when compact.
        private var height: CGFloat { compact ? 24 : 28 }

        var body: some View {
            Button(action: action) {
                title
                    .font(compact ? .body : .callout)
                    .lineLimit(1)
                    .foregroundStyle(selected ? Palette.onAccent : Color.secondary)
                    .padding(.horizontal, compact ? 10 : 12)
                    .frame(height: height)
                    .background {
                        if hovered && !selected { Capsule().fill(Palette.hoverFill) }
                    }
                    .matchedGeometryEffect(id: tab, in: namespace)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// A small on/off switch, dimmed when disabled; the system switch stays wide even at `.mini` on macOS 26.
struct CompactSwitch: ToggleStyle {
    static let height: CGFloat = 19

    func makeBody(configuration: Configuration) -> some View {
        Switch(configuration: configuration)
    }

    private struct Switch: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            // A Button, not a tap gesture: keyboard navigation reaches it and Space toggles it.
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : Palette.switchOffFill)
                    .frame(width: 34, height: CompactSwitch.height)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .shadow(color: Palette.knobShadow, radius: 0.5, y: 0.5)
                            .padding(1.5)
                    }
                    .animation(reduceMotion ? nil : Motion.toggle, value: configuration.isOn)
                    .contentShape(Capsule())
            }
            .buttonStyle(Bare())
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }

    /// The label as is: `.plain` dims a disabled label on top of the switch's own dimming.
    private struct Bare: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { configuration.label }
    }
}

/// A disclosure row whose chevron sits on the title's line, not halfway down a title with a subtitle. A click anywhere
/// on the header row toggles it, not only on the chevron; the row's own controls (its switch) keep their clicks.
struct TitleChevronDisclosureStyle: DisclosureGroupStyle {
    /// The chevron's width: content inset by it lines up with the title.
    nonisolated static let indent: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        TitleChevronDisclosure(configuration: configuration)
    }
}

private struct TitleChevronDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: TitleChevronDisclosureStyle.indent, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(configuration.isExpanded ? "Collapse" : "Expand")
                configuration.label
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if configuration.isExpanded { configuration.content }
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : Motion.toggle) {
            configuration.$isExpanded.wrappedValue.toggle()
        }
    }
}

/// The translucent window background, blurring what is behind the window (toolbar included), under a tint so only a
/// little shows through. The tint follows a live dark/light switch.
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        let tint = TintView(frame: view.bounds)
        tint.autoresizingMask = [.width, .height]
        view.addSubview(tint)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// A layer color resolves once, so it is set again in `updateLayer()`, which AppKit calls on an appearance change.
    private final class TintView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
        }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = Palette.windowTint.cgColor
            }
        }
    }
}

/// A card or panel: solid `Palette.surface` with a 1 pt `Palette.surfaceBorder` edge, on every macOS version, so it
/// stands out from the window background. Raised (a sidebar, an entry card) looks like the toolbar's capsules: a rim
/// lit from above, a faint sheen at the top and a soft shadow under it. Radii: 20 raised (sidebar, modal, entry card),
/// 14 content cards (`SettingsMetrics.cardRadius`), 10 inputs (`SettingsInputMetrics.cornerRadius`).
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 14
    var raised = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if raised {
            content
                .background {
                    shape.fill(Palette.surface)
                        .overlay(shape.fill(Palette.cardSheen))
                        .shadow(color: Palette.cardShadow, radius: 6, y: 3)
                }
                .overlay(shape.strokeBorder(Palette.raisedRim, lineWidth: 1).allowsHitTesting(false))
        } else {
            content
                .background(shape.fill(Palette.surface))
                .overlay(shape.strokeBorder(Palette.surfaceBorder, lineWidth: 1).allowsHitTesting(false))
        }
    }
}

/// On macOS 26+ (unless `--force-fallbacks`), scrolled content stops hard at the top edge instead of fading under
/// the transparent title bar.
struct HardTopScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *), PlatformFeatures.liquidGlass {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

extension ToolbarContent {
    /// On macOS 26+ (unless `--force-fallbacks`), the toolbar draws no glass behind this item, so it does not share
    /// the capsule of the items next to it.
    @ToolbarContentBuilder
    func hiddenSharedBackground() -> some ToolbarContent {
        if #available(macOS 26, *), PlatformFeatures.liquidGlass {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// Spacing of the settings pages (a 4 pt scale). The sidebar card starts at the top of the content area, about 8 pt
/// under the header's capsules, and the page beside it starts at the same top edge: its first element (a card's
/// title, or the card itself) is top-aligned with the sidebar card. Only the tab layout, which has no sidebar, starts
/// its page `contentTopOffset` lower.
enum SettingsMetrics {
    /// Corner radius of a content card (`GlassCard`'s default).
    static let cardRadius: CGFloat = 14
    /// Inner padding of a card: its rows' sides, a card header, a modal header.
    static let cardPadding: CGFloat = 12
    /// Gap between two cards of a page.
    static let cardSpacing: CGFloat = 16
    /// Space above and below each row of a `SettingsGroup` (a divider sits in the middle of two rows' padding).
    static let rowPadding: CGFloat = 10
    /// Outer padding of a page's scroll content (trailing, bottom, and leading without a sidebar).
    static let pagePadding: CGFloat = 20
    /// The sidebar card: width, corner radius, rows' inset inside it.
    static let sidebarWidth: CGFloat = 200
    static let sidebarRadius: CGFloat = 20
    static let sidebarRowsPadding: CGFloat = 10
    /// The sidebar card's inset from the window's leading and bottom edges, and the gap from it to the page.
    static let sidebarInset: CGFloat = 12
    /// Tab layout only: the page's top gap under the top of the content area (about 20 pt under the header's
    /// capsules). Never in the sidebar layout, whose page is top-aligned with the sidebar card.
    static let contentTopOffset: CGFloat = 12
}

extension Font {
    /// Small text in the Settings window: row hints, warnings and errors, footers, banners, badges and small button
    /// labels. One step above the system caption (11 pt, not 10) and still below row titles (13 pt).
    static let settingsCaption: Font = .subheadline
}

/// A titled card of settings rows, with an optional description above the card (secondary body text, like a page
/// intro). It replaces a grouped `Form`, which macOS
/// caps at about 700 pt and centers; these cards fill the column. Separate the rows with `SettingsDivider()`, and give
/// the page `.labeledContentStyle(.settingsRow)`.
struct SettingsGroup<Content: View>: View {
    let title: String?
    let description: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String?, description: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.description = description
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, SettingsMetrics.cardPadding)
            }
            if let description {
                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.cardPadding)
                    .padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, SettingsMetrics.cardPadding)
            .padding(.vertical, SettingsMetrics.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
        }
    }
}

/// The divider between two rows of a `SettingsGroup`, with the rows' vertical padding around it.
struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, SettingsMetrics.rowPadding)
    }
}

/// A row of a `SettingsGroup` for `LabeledContent`: the label (a title, then an optional `.settingsCaption` `.secondary` hint)
/// leading, the control trailing. The label dims like the controls when the row is disabled.
struct SettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                configuration.label
            }
            .fixedSize(horizontal: false, vertical: true)
            .modifier(DimmedWhenDisabled())
            Spacer(minLength: 12)
            configuration.content
        }
    }

    private struct DimmedWhenDisabled: ViewModifier {
        @Environment(\.isEnabled) private var isEnabled

        func body(content: Content) -> some View {
            content.opacity(isEnabled ? 1 : 0.45)
        }
    }
}

extension LabeledContentStyle where Self == SettingsRowStyle {
    /// Title and hint leading, control trailing (see `SettingsRowStyle`).
    static var settingsRow: SettingsRowStyle { SettingsRowStyle() }
}

/// The text inputs on a card: a rounded field of the input color with a 1 pt edge; the focused field gets an accent
/// edge instead of the system's square focus ring. The text sits inside the fill, clear of the rounded corners.
enum SettingsInputMetrics {
    /// The small inset-card radius.
    static let cornerRadius: CGFloat = 10
    /// As tall as a 28 pt row button; a multi-line field grows past it.
    static let minHeight: CGFloat = 28
}

/// `TextField` / `SecureField` style: `.textFieldStyle(.settings)`. A main-actor conformance: the protocol's `_body` is
/// not isolated, and the field view it builds is.
@MainActor
struct SettingsTextFieldStyle: @MainActor TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        Field(configuration: configuration)
    }

    private struct Field: View {
        let configuration: TextField<SettingsTextFieldStyle._Label>
        @FocusState private var focused: Bool

        var body: some View {
            configuration
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minHeight: SettingsInputMetrics.minHeight)
                .modifier(SettingsInputChrome(focused: focused))
        }
    }
}

extension TextFieldStyle where Self == SettingsTextFieldStyle {
    static var settings: SettingsTextFieldStyle { SettingsTextFieldStyle() }
}

extension View {
    /// The `.textFieldStyle(.settings)` look for a multi-line `TextEditor`: its own background hidden and the text
    /// inset, so the first line, the caret and the scroller sit inside the rounded corners.
    func settingsTextEditor() -> some View {
        modifier(SettingsTextEditorStyle())
    }
}

private struct SettingsTextEditorStyle: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .modifier(SettingsInputChrome(focused: focused))
    }
}

/// The rounded fill, the edge (accent while focused) and the disabled dimming shared by both input styles.
private struct SettingsInputChrome: ViewModifier {
    let focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
        content
            .focusEffectDisabled()
            .background(shape.fill(Palette.inputSurface))
            .overlay(shape.strokeBorder(focused ? Color.accentColor : Palette.surfaceBorder, lineWidth: focused ? 1.5 : 1))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Motion.hover, value: focused)
    }
}

/// The page behind an open `SettingsModal`.
enum SettingsModalBackdrop {
    /// A light blur of the page behind the scrim, so its sidebar and cards stay faintly readable. The caller applies it
    /// to the page with `.blur(radius:opaque: false)`, animated with the scrim.
    static let blurRadius: CGFloat = 2.5
}

/// A centered in-window modal: a `Palette.scrim` over the area it fills (a click dismisses it unless
/// `dismissOnBackdropTap` is false), and a raised `GlassCard` (radius 20) `min(area - 80, 760)` wide, floored at
/// `minWidth`, as tall as the area minus 40 pt above and below. Not a `.sheet`, so it looks the same on every macOS.
/// Put it last in the page's root `ZStack`. It fades in and scales from 0.96 with the caller's `Motion.sheet` and
/// leaves with `Motion.exit` (a fade only under Reduce Motion); the scrim click and Esc close it with `Motion.sheet`.
struct SettingsModal<Content: View>: View {
    let isPresented: Bool
    /// The width of the area it fills; the card sizes itself from it.
    let containerWidth: CGFloat
    /// The card's minimum width: the content's own minimum.
    var minWidth: CGFloat = 480
    /// When false, a scrim click does nothing (it still blocks the page): for unsaved input, closed only by its own
    /// buttons or Esc.
    var dismissOnBackdropTap = true
    /// Called when a scrim click or Esc dismisses it.
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var sideMargin: CGFloat { 40 }
    /// From the area's top and bottom edges. 40 also clears the traffic lights (they end at about y 33) when the
    /// modal fills the whole window.
    private static var verticalMargin: CGFloat { 40 }
    private static var maxWidth: CGFloat { 760 }
    private static var cornerRadius: CGFloat { 20 }

    private var cardWidth: CGFloat {
        max(minWidth, min(containerWidth - 2 * Self.sideMargin, Self.maxWidth))
    }

    /// In with the caller's animation, out faster.
    private var scrimTransition: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.exit))
    }

    /// A fade and a scale from 0.96, centered; a fade only under Reduce Motion.
    private var cardTransition: AnyTransition {
        if reduceMotion {
            return .asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.exit))
        }
        let fadeScale = AnyTransition.opacity.combined(with: .scale(scale: 0.96))
        return .asymmetric(insertion: fadeScale, removal: fadeScale.animation(Motion.exit))
    }

    private func dismiss() {
        withAnimation(Motion.sheet) { onDismiss() }
    }

    var body: some View {
        // One layer in both states. To fill the whole window (a header drawn by SwiftUI, no SwiftUI toolbar), the
        // caller puts `.ignoresSafeArea()` on this view, never inside the `if`s: on a view being inserted it takes
        // effect only when the transition ends, so the card would animate in too low and then jump up.
        ZStack {
            if isPresented {
                Rectangle()
                    .fill(Palette.scrim)
                    .onTapGesture {
                        if dismissOnBackdropTap { dismiss() }
                    }
                    .transition(scrimTransition)
                    .zIndex(1)
            }
            if isPresented {
                let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                content()
                    .frame(width: cardWidth)
                    .frame(maxHeight: .infinity)
                    // Clip before the card's background: dividers and scroll views stay inside the rounded corners,
                    // the shadow is not cut.
                    .clipShape(shape)
                    .modifier(GlassCard(cornerRadius: Self.cornerRadius, raised: true))
                    .onExitCommand(perform: dismiss)
                    .padding(.vertical, Self.verticalMargin)
                    .transition(cardTransition)
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
