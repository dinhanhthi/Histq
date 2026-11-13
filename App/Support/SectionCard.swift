// The card every part of a panel sits in: the repo sidebar's sections, the commit list, the detail's parts, the
// Welcome page's parts. Cards stack with `SectionCardMetrics.spacing` between them, on the window glass.
import SwiftUI

enum SectionCardMetrics {
    /// Between two stacked cards.
    static let spacing: CGFloat = 8
}

/// A titled card (`GlassCard`: surface fill, 1 pt `surfaceBorder` edge, the content cards' radius). Its header holds
/// an optional icon, the title, an optional count (a skeleton bar while `countIsLoading`) and, when `isExpanded` is
/// given, a chevron: a click on the header collapses or expands the body at once.
struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String?
    let count: Int?
    let countIsLoading: Bool
    let isExpanded: Binding<Bool>?
    /// Around the body, below the header: smaller for rows that draw their own capsules.
    let contentPadding: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        _ title: String, systemImage: String? = nil, count: Int? = nil, countIsLoading: Bool = false,
        isExpanded: Binding<Bool>? = nil, contentPadding: CGFloat = SettingsMetrics.cardPadding,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.countIsLoading = countIsLoading
        self.isExpanded = isExpanded
        self.contentPadding = contentPadding
        self.content = content
    }

    private static var headerHeight: CGFloat { 32 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let isExpanded {
                Button {
                    withAnimation(reduceMotion ? nil : Motion.toggle) { isExpanded.wrappedValue.toggle() }
                } label: {
                    header(chevron: isExpanded.wrappedValue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
                .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
            } else {
                header(chevron: nil)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
            }
            if isExpanded?.wrappedValue ?? true {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom], contentPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
        .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
    }

    /// `chevron`: nil when the card does not collapse, else whether it is expanded.
    private func header(chevron expanded: Bool?) -> some View {
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
