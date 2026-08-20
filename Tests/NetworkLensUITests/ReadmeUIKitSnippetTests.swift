//
//  ReadmeUIKitSnippetTests.swift
//  NetworkLensUITests
//
//  Created by Rohit Sahay on 05/08/26.
//

import XCTest
@testable import NetworkLensUI

#if canImport(UIKit)
import UIKit

/// The README's legacy-UIKit code, compiled.
///
/// The overlay snippets are the easiest thing in the README to get wrong,
/// because they are the only ones that touch UIKit lifecycle and so cannot be
/// checked by the macOS test run that CI does. They are pasted here almost
/// verbatim; when a signature moves, this fails instead of a reader's build.
///
/// Run the package against an iOS simulator destination to get anything out of
/// this file — on macOS it compiles away to nothing.
final class ReadmeUIKitSnippetTests: XCTestCase {

    func testLegacyAppDelegateSnippetCompiles() {
        XCTAssertNotNil(LegacyAppDelegate.self)
    }

    func testObjectiveCShimSnippetCompiles() {
        XCTAssertNotNil(LensBootstrap.self)
    }

    func testViewControllerAttributionSnippetCompiles() {
        let controller = CheckoutViewController()
        // Driving the lifecycle would need a window and a runloop turn; the
        // value here is that push/pop typecheck against the real signatures,
        // which is where the README was wrong before.
        XCTAssertNotNil(controller)
    }
}

// MARK: - README: legacy UIKit integration

private final class LegacyAppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        NetworkLens.start()

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController()
        window?.makeKeyAndVisible()

        showLensOverlay()
        return true
    }

    private func showLensOverlay() {
        if let scene = window?.windowScene {
            NetworkLens.attachOverlay(to: scene)
            return
        }

        DispatchQueue.main.async {
            NetworkLens.attachOverlayToActiveScene()
        }
    }
}

// MARK: - README: Objective-C shim

@objc private final class LensBootstrap: NSObject {

    @objc static func start() {
        NetworkLens.start()
    }

    @MainActor
    @objc static func attachOverlay(to window: UIWindow) {
        guard let scene = window.windowScene else { return }
        NetworkLens.attachOverlay(to: scene)
    }
}

// MARK: - README: screen attribution from a view controller

private final class CheckoutViewController: UIViewController {

    private var lensToken: UUID?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lensToken = ScreenContext.shared.push("Checkout")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let lensToken { ScreenContext.shared.pop(lensToken) }
    }
}
#endif
