import SwiftUI
import UIKit

/// Hosts a SwiftUI view in its own UIKit layer so it can sit *above* a
/// `UIViewRepresentable` sibling.
///
/// SwiftUI draws ordinary views into the hosting view's own layer, and
/// places platform views (a collection view, a map) as real subviews on top
/// of that layer. A SwiftUI button declared after a representable in a
/// ZStack therefore renders above it but hit-tests *below* it: the touch
/// lands in the UIKit view. The jump-to-bottom button over the transcript
/// was exactly that — its taps went to the bubble behind it. Wrapping the
/// button in this makes it a platform view too, inserted after the
/// collection view, so both drawing and hit-testing agree.
///
/// The hosted controller is sized to its content; it never covers more
/// than the view it wraps.
struct HostedAboveUIKit<Content: View>: UIViewControllerRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content)
        controller.view.backgroundColor = .clear
        controller.sizingOptions = .intrinsicContentSize
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        controller.rootView = content
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController controller: UIHostingController<Content>,
        context: Context
    ) -> CGSize? {
        controller.sizeThatFits(in: proposal.replacingUnspecifiedDimensions(by: CGSize(width: 10_000, height: 10_000)))
    }
}
