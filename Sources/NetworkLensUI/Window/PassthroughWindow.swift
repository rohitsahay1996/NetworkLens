#if canImport(UIKit)
import UIKit
import SwiftUI

/// A window that is invisible to touches except where it actually has content.
///
/// Without this the overlay swallows every tap in the app and the tool is
/// unusable.
///
/// Comparing the hit view against the root view does **not** work here, however
/// obvious it looks: SwiftUI draws the whole hierarchy into the hosting view
/// itself rather than into child `UIView`s, so every point — bubble included —
/// hit-tests to the root view, and rejecting those rejects everything. The
/// content has to tell the window where it actually is, which is what
/// `interactiveRects` is for.
public final class PassthroughWindow: UIWindow {

    /// Regions, in window coordinates, that should receive touches. Everything
    /// outside them falls through to the app.
    public var interactiveRects: [CGRect] = []

    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // A presented sheet owns the whole screen and is modal over the app, so
        // the passthrough rule is suspended while one is up. Without this the
        // inspector would be visible but untouchable.
        if rootViewController?.presentedViewController != nil {
            return super.hitTest(point, with: event)
        }

        guard interactiveRects.contains(where: { $0.contains(point) }) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Hosts the overlay content and keeps the root view transparent, so the app
/// shows through everywhere the overlay is not drawing.
final class OverlayHostingController<Content: View>: UIHostingController<Content> {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}

/// Carries the bubble's on-screen frame up to the window.
struct BubbleFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
#endif
