//
//  WindowSnapshot.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 28/08/26.
//

#if canImport(UIKit)
import UIKit

/// Screenshots the app, not the tool.
///
/// The overlay lives in its own `PassthroughWindow` above the app's, so a naive
/// screen capture puts the bubble and the run bar in every frame — over the
/// exact corner of the screen someone is trying to review. Rendering the app's
/// own window instead leaves the evidence clean.
///
/// `drawHierarchy(afterScreenUpdates:)` rather than `layer.render(in:)`: the
/// layer path misses anything drawn out of process, which on this app means
/// most images and any visual effect view — a screenshot with holes in it is
/// worse than none, because nobody can tell the holes from a bug.
enum WindowSnapshot {

    /// PNG of the frontmost app window in the given scene, or nil when there is
    /// nothing to draw yet.
    @MainActor
    static func capture(in scene: UIWindowScene?) -> Data? {
        guard let window = appWindow(in: scene) else { return nil }
        guard window.bounds.width > 0, window.bounds.height > 0 else { return nil }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return image.pngData()
    }

    /// The app's own window: last in order, excluding ours.
    ///
    /// Excluded by type rather than by level or by tag, because a host app is
    /// free to put its own window at any level and the tool must not guess
    /// which of two windows belongs to whom.
    @MainActor
    private static func appWindow(in scene: UIWindowScene?) -> UIWindow? {
        let scenes: [UIWindowScene] = scene.map { [$0] }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }

        let candidates = scenes
            .flatMap(\.windows)
            .filter { !($0 is PassthroughWindow) && !$0.isHidden && $0.alpha > 0 }

        return candidates.first { $0.isKeyWindow } ?? candidates.last
    }
}
#endif
