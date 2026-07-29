import Foundation

// Re-exported so a host app has a single import for the whole umbrella API,
// and so swapping `import NetworkLensUI` for `import NetworkLensNoOp` is the
// only edit a release build needs.
@_exported import NetworkLensCore

#if canImport(UIKit)
import UIKit

extension NetworkLens {

    /// Attaches the floating overlay to a scene.
    ///
    /// Takes the scene rather than reaching for the app delegate's window:
    /// that breaks on iPad multi-window and in any scene-based app.
    public static func attachOverlay(to scene: UIWindowScene) {
        // Overlay window lands with the UI commit, gated on API sign-off.
        _ = scene
    }
}
#endif
