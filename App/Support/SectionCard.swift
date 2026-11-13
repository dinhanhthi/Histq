// The card every part of a panel sits in: the repo sidebar's sections, the commit list, the detail's parts, the
// Welcome page's parts. Cards stack with `SectionCardMetrics.spacing` between them, in a repo panel's
// `PanelContainer` (below) or on the window glass (Welcome).
import SwiftUI

enum SectionCardMetrics {
    /// Between two stacked cards.
    static let spacing: CGFloat = 8
}

/// A titled card (`GlassCard`: surface fill, 1 pt `surfaceBorder` edge, the content cards' radius). Its header holds
/// an optional icon, the title, an optional count (a skeleton bar while `countIsLoading`) and, when `isExpanded` is
/// given, a chevron: a click on the header collapses or expands the body at once. `accessory` sits at the header's
/// trailing edge (small buttons such as "Stage all"). A nil `title` gives a card without a header (the commit graph,
/// whose column titles are its header); its body then fills the card to the top.
struct SectionCard<Content: View, Accessory: View>: View {
    let title: String?
    let systemImage: String?
    let count: Int?
    let countIsLoading: Bool
    let isExpanded: Binding<Bool>?
    /// Around the body, below the header: smaller for rows that draw their own capsules.
    let contentPadding: CGFloat
    @ViewBuilder let content: () -> Content
    @ViewBuilder let accessory: () -> Accessory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        _ title: String?, systemImage: String? = nil, count: Int? = nil, countIsLoading: Bool = false,
        isExpanded: Binding<Bool>? = nil, contentPadding: CGFloat = SettingsMetrics.cardPadding,
        @ViewBuilder content: @escaping () -> Content, @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.countIsLoading = countIsLoading
        self.isExpanded = isExpanded
        self.contentPadding = contentPadding
        self.content = content
        self.accessory = accessory
    }

    private static var headerHeight: CGFloat { 32 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 0) {
                    if let isExpanded {
                        Button {
                            withAnimation(reduceMotion ? nil : Motion.toggle) { isExpanded.wrappedValue.toggle() }
                        } label: {
                            header(title, chevron: isExpanded.wrappedValue)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
                        .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
                    } else {
                        header(title, chevron: nil)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                    }
                    accessory()
                        .padding(.trailing, SettingsMetrics.cardPadding)
                }
            }
            if isExpanded?.wrappedValue ?? true {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(title == nil ? .all : [.horizontal, .bottom], contentPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
        .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
    }

    /// `chevron`: nil when the card does not collapse, else whether it is expanded.
    private func header(_ title: String, chevron expanded: Bool?) -> some View {
        HStack(spacing: 6) {
            if let expanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                    .foregroundStyle(.secondary)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            if countIsLoading {
                SkeletonLine(width: 14, height: 11)
            } else if let count {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, isExpanded == nil ? SettingsMetrics.cardPadding : 10)
        .frame(height: Self.headerHeight)
        .contentShape(Rectangle())
    }
}

extension SectionCard where Accessory == EmptyView {
    init(
        _ title: String?, systemImage: String? = nil, count: Int? = nil, countIsLoading: Bool = false,
        isExpanded: Binding<Bool>? = nil, contentPadding: CGFloat = SettingsMetrics.cardPadding,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title, systemImage: systemImage, count: count, countIsLoading: countIsLoading, isExpanded: isExpanded,
                  contentPadding: contentPadding, content: content, accessory: { EmptyView() })
    }
}

/// The outer container of a repo panel (sidebar, graph / diff / conflict editor, detail) and of the tab row: a
/// rounded `Palette.bgCard` fill with a 1 pt `surfaceBorder` edge, `padding` inside it. Its cards sit one step above
/// it, so the window, the container and the cards read as three levels. A flat fill on purpose: no material, glass
/// effect or shadow, which would add work to every redraw of the click's frame. The default radius keeps the corners
/// concentric with the cards' (`SettingsMetrics.cardRadius` + `padding`).
struct PanelContainer<Content: View>: View {
    var padding: CGFloat = PanelContainerMetrics.padding
    var cornerRadius: CGFloat?
    @ViewBuilder let content: () -> Content

    var body: some View {
        let radius = cornerRadius ?? SettingsMetrics.cardRadius + padding
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content()
            .padding(padding)
            .background(shape.fill(Palette.bgCard))
            .overlay(shape.strokeBorder(Palette.surfaceBorder, lineWidth: 1).allowsHitTesting(false))
    }
}

enum PanelContainerMetrics {
    /// Between a container's edge and the cards inside it.
    static let padding: CGFloat = 6
}
