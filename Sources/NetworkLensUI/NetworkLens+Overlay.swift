//
//  NetworkLens+Overlay.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 29/07/26.
//

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
    ///
    /// Safe to call more than once per scene; the second call is a no-op.
    @MainActor
    public static func attachOverlay(to scene: UIWindowScene) {
        OverlayWindowController.shared.attach(to: scene)
    }

    @MainActor
    public static func detachOverlay(from scene: UIWindowScene) {
        OverlayWindowController.shared.detach(from: scene)
    }

    /// Attaches to whichever scene is currently foregrounded.
    ///
    /// The convenience a SwiftUI app wants, because a pure-SwiftUI lifecycle
    /// has no natural place to get a `UIWindowScene` handle. Prefer
    /// `attachOverlay(to:)` from a scene delegate when the app has one — this
    /// one can only guess, and on iPad with two windows open it guesses once.
    @MainActor
    @discardableResult
    public static func attachOverlayToActiveScene() -> Bool {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        guard let scene else { return false }
        OverlayWindowController.shared.attach(to: scene)
        return true
    }
}

import SwiftUI

extension View {

    /// Attaches the overlay to whichever scene this view ends up in.
    ///
    /// The entry point for a pure-SwiftUI app, which never sees a scene
    /// delegate. Driven by scene activation rather than by `onAppear`, so it
    /// attaches to each window separately on iPad instead of guessing once and
    /// leaving the second window without a bubble.
    public func networkLensOverlay() -> some View {
        modifier(NetworkLensOverlayModifier())
    }
}

private struct NetworkLensOverlayModifier: ViewModifier {

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) {
                guard let scene = $0.object as? UIWindowScene else { return }
                NetworkLens.attachOverlay(to: scene)
            }
            // Scene activation has usually already happened by the time the
            // first view appears, so the notification alone would miss launch.
            .onAppear { NetworkLens.attachOverlayToActiveScene() }
    }
}
#endif
