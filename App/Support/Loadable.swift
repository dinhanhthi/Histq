// Loading states for a detail that switches at once and fills in later: the state itself, a placeholder with the
// content's shape, and a spinner that only shows when the load is slow. The views log the DEBUG timing lines.
import SwiftUI

/// A value loaded off the main actor. A click sets `.loading` in the same frame; `.loaded` replaces it once the
/// value is ready. A cancelled load never becomes `.failed`.
enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    /// A message for the user.
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

extension Loadable: Sendable where Value: Sendable {}
extension Loadable: Equatable where Value: Equatable {}

/// Stands in for a card until its content loads: `content` is the card's skeleton (`SkeletonLine` bars in the
/// content's layout, so it has the loaded content's footprint), with a `DelayedSpinner` over it. Logs
/// `placeholder <detail>` when it appears and again for each new `token` (a newer select while it still shows).
struct PlaceholderCard<Token: Hashable, Content: View>: View {
    /// Changes with each select; a new value logs a new `placeholder` line.
    let token: Token
    /// The timing log's detail (`overview graph`).
    let detail: String
    /// Whether the placeholder is still the one the user looks at (see `DelayedSpinner.isCurrent`).
    var isCurrent: @MainActor () -> Bool = { true }
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .allowsHitTesting(false)
            .overlay { DelayedSpinner(detail: detail, isCurrent: isCurrent) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
            .onChange(of: token, initial: true) { UITiming.placeholder(detail) }
    }
}

/// A line of a loading placeholder: a static capsule of `Palette.skeletonFill`, `height` tall (about the line's font
/// size). `width` fixes its width; otherwise it takes `fraction` of the width it is offered. An icon is a
/// `SkeletonLine(width: h, height: h)`, a circle.
struct SkeletonLine: View {
    var width: CGFloat?
    var fraction: CGFloat = 1
    var height: CGFloat = 12

    var body: some View {
        if let width {
            bar.frame(width: width, height: height)
        } else {
            GeometryReader { proxy in
                bar.frame(width: max(height, proxy.size.width * fraction), height: height)
            }
            .frame(height: height)
        }
    }

    private var bar: some View {
        Capsule().fill(Palette.skeletonFill)
    }
}

/// A small spinner that fades in only when a load takes over 150 ms, so a fast load never flashes it. Logs
/// `spinner <detail>` when it shows. Under Reduce Motion it appears without the fade.
struct DelayedSpinner: View {
    let detail: String
    /// Checked when the delay ends. A view switched away can still be alive then (SwiftUI delivers its removal with
    /// the next display, which takes over 100 ms right after launch), so its spinner must not show or log.
    var isCurrent: @MainActor () -> Bool = { true }
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long a load may take before the spinner shows.
    static let delay: Duration = .milliseconds(150)

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(visible ? 1 : 0)
            .task {
                // Cancelled when the placeholder goes away (the content loaded first).
                guard (try? await Task.sleep(for: Self.delay)) != nil, isCurrent() else { return }
                withAnimation(reduceMotion ? nil : Motion.standard) { visible = true }
                UITiming.spinner(detail)
            }
    }
}
