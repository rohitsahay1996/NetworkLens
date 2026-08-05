//
//  OverlayWindowController.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import UIKit
import SwiftUI
import NetworkLensCore

/// Owns the overlay window for one scene.
///
/// Keyed by scene rather than by app: attaching to the app delegate's window
/// breaks on iPad multi-window and in any scene-based app, and produces two
/// bubbles fighting over one window in split view.
@MainActor
public final class OverlayWindowController {

    public static let shared = OverlayWindowController()

    private var windows: [ObjectIdentifier: PassthroughWindow] = [:]

    public init() {}

    public func attach(to scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard windows[key] == nil else { return }

        let window = PassthroughWindow(windowScene: scene)
        // Below .alert so system alerts still come out on top — the tool must
        // never hide a permission prompt the tester needs to answer.
        window.windowLevel = .alert - 1
        window.backgroundColor = .clear
        window.isHidden = false

        // The window can only pass touches through if it knows where the
        // bubble is, and the bubble moves, so the frame is reported live
        // rather than read once at attach time.
        let root = OverlayHostingController(
            rootView: OverlayRootView { [weak window] frame in
                window?.interactiveRects = [frame]
            }
        )
        root.view.backgroundColor = .clear
        window.rootViewController = root

        windows[key] = window
    }

    public func detach(from scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        windows[key]?.isHidden = true
        windows[key] = nil
    }

    public var isAttached: Bool { !windows.isEmpty }
}

/// Everything the overlay draws: the bubble, the inspector sheet, and the
/// breakpoint sheet.
struct OverlayRootView: View {

    /// Reports the bubble's window-space frame so `PassthroughWindow` can hit
    /// test against it.
    let onBubbleFrameChange: (CGRect) -> Void

    @StateObject private var lens = LensObservable.shared
    @State private var isInspectorPresented = false

    var body: some View {
        FloatingBubble(
            exchangeCount: lens.exchanges.count,
            hasArmedBreakpoints: lens.breakpoints.contains { $0.isEnabled },
            isHolding: lens.presentation.isHolding,
            isMocking: lens.isServingMocks
        ) {
            isInspectorPresented = true
        }
        .onPreferenceChange(BubbleFrameKey.self, perform: onBubbleFrameChange)
        // A view controller can only present one thing at a time, so the
        // inspector has to get out of the way rather than compete. Dropping it
        // is the right way round: the app is stopped behind the breakpoint, and
        // the traffic list will still be there afterwards.
        .onChange(of: lens.presentation.isHolding) { isHolding in
            if isHolding { isInspectorPresented = false }
        }
        .sheet(isPresented: $isInspectorPresented) {
            InspectorView()
                .environmentObject(lens)
        }
        // On its own host view, not a second `.sheet` on the bubble. SwiftUI
        // honours one presentation per view and silently drops the rest, so
        // stacking both here left whichever lost the race unable to present —
        // a breakpoint that holds the app behind a sheet nobody can see.
        .background(
            Color.clear
                // Driven by the coordinator rather than by a tap: a breakpoint
                // can fire while the tester is reading the traffic list, and it
                // has to win — the app is stopped behind it.
                .sheet(isPresented: .constant(lens.presentation.isHolding)) {
                    BreakpointSheet()
                        .environmentObject(lens)
                        .interactiveDismissDisabled()
                }
        )
    }
}

/// Tabs for the inspector surfaces.
struct InspectorView: View {

    @EnvironmentObject private var lens: LensObservable
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            tab { ExchangeListView() }
                .tabItem { Label("Traffic", systemImage: "list.bullet") }

            tab { MockListView() }
                .tabItem { Label("Mocks", systemImage: "square.on.square") }

            tab { ScenarioListView() }
                .tabItem { Label("Setups", systemImage: "square.stack.3d.down.right") }

            tab { BreakpointListView() }
                .tabItem { Label("Breakpoints", systemImage: "pause.circle") }

            tab { SessionStatsView() }
                .tabItem { Label("Stats", systemImage: "chart.bar") }
        }
    }

    /// Each tab gets its own navigation stack, so drilling into an exchange in
    /// one tab does not leave another tab pushed somewhere the tester did not
    /// put it. `.stack` because the default splits on iPad and strands the
    /// detail pane.
    private func tab<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationView {
            content()
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
        .environmentObject(lens)
    }
}
#endif
