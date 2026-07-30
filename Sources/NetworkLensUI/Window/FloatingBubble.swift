//
//  FloatingBubble.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import SwiftUI

/// The draggable entry point. Goes wherever it is dropped and remembers it.
struct FloatingBubble: View {

    let exchangeCount: Int
    let hasArmedBreakpoints: Bool
    /// Tinted while a breakpoint is held, so the tester can see the app is
    /// paused rather than hung.
    let isHolding: Bool
    /// Mocks are being served. Shown on the bubble because it is the only part
    /// of the tool visible while someone is using the app itself, and "am I
    /// looking at real data?" is a question that has to be answerable without
    /// opening anything.
    var isMocking = false
    let onTap: () -> Void

    static let size: CGFloat = 56

    @State private var position: CGPoint?
    @State private var drag: CGSize = .zero
    @GestureState private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let resting = position ?? BubblePosition.load(in: geometry.size)
                ?? BubblePosition.default(in: geometry.size)

            // Everything below is attached to the 56×56 content and `.position`
            // is applied last, deliberately. `.position` returns a view that
            // fills all available space: measuring or attaching a gesture after
            // it covers the whole screen, which reports the entire screen as
            // touchable and puts a screen-sized drag gesture over the app.
            bubbleBody
                .contentShape(Circle())
                // The window hit-tests against this rect, so it has to follow
                // the bubble live — a stale frame means a dragged bubble that
                // no longer takes taps.
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: BubbleFrameKey.self,
                            value: proxy.frame(in: .global)
                        )
                    }
                )
                .onTapGesture(perform: onTap)
                // Far enough that a sloppy tap is not stolen by the drag.
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .updating($isDragging) { _, state, _ in state = true }
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            let moved = CGPoint(
                                x: resting.x + value.translation.width,
                                y: resting.y + value.translation.height
                            )
                            // Free placement — no edge snapping. Clamped only
                            // so it cannot be dropped somewhere it can never be
                            // picked up again.
                            let settled = BubblePosition.clamped(moved, in: geometry.size)
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                position = settled
                                drag = .zero
                            }
                            BubblePosition.save(settled, in: geometry.size)
                        }
                )
                .position(
                    x: resting.x + drag.width,
                    y: resting.y + drag.height
                )
        }
        .ignoresSafeArea()
    }

    private var bubbleBody: some View {
        ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .overlay(Circle().strokeBorder(tint.opacity(0.6), lineWidth: 2))
                    .shadow(radius: isDragging ? 12 : 4, y: 2)

            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: Self.size, height: Self.size)
        .overlay(alignment: .topTrailing) {
            if exchangeCount > 0 {
                Text(exchangeCount > 99 ? "99+" : "\(exchangeCount)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tint))
                    .foregroundStyle(.white)
                    .offset(x: 4, y: -2)
            }
        }
        .scaleEffect(isDragging ? 1.1 : 1)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("NetworkLens")
        .accessibilityValue("\(exchangeCount) requests captured")
    }

    private var icon: String {
        if isHolding { return "pause.fill" }
        if isMocking { return "square.on.square" }
        return "antenna.radiowaves.left.and.right"
    }

    /// Semantic colours only, so dark mode and high contrast come free.
    ///
    /// Mocking takes purple, which is what every badge in this UI already uses
    /// for synthetic traffic; armed breakpoints move to indigo rather than share
    /// it. Serving fake data outranks an armed-but-unfired breakpoint because it
    /// is already changing what the tester sees.
    private var tint: Color {
        if isHolding { return .orange }
        if isMocking { return .purple }
        if hasArmedBreakpoints { return .indigo }
        return .accentColor
    }
}

/// Position persistence and bounds clamping.
///
/// Stored as a fraction of the screen rather than a point, so rotating the
/// device or moving to a different-sized window does not park the bubble
/// off-screen.
enum BubblePosition {

    private static let xKey = "com.networklens.bubble.x"
    private static let yKey = "com.networklens.bubble.y"
    private static let inset: CGFloat = 36

    static func `default`(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width - inset, y: size.height * 0.4)
    }

    static func load(in size: CGSize) -> CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: xKey) != nil, defaults.object(forKey: yKey) != nil else {
            return nil
        }
        return CGPoint(
            x: CGFloat(defaults.double(forKey: xKey)) * size.width,
            y: CGFloat(defaults.double(forKey: yKey)) * size.height
        )
    }

    static func save(_ point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let defaults = UserDefaults.standard
        defaults.set(Double(point.x / size.width), forKey: xKey)
        defaults.set(Double(point.y / size.height), forKey: yKey)
    }

    /// Kept fully on screen, and nothing more.
    ///
    /// Deliberately not snapped to an edge: the bubble covers whatever is
    /// under it, and the thing a tester needs to see is as likely to be at an
    /// edge as in the middle. Parking is their call.
    static func clamped(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let radius = FloatingBubble.size / 2
        return CGPoint(
            x: min(max(point.x, radius), max(radius, size.width - radius)),
            y: min(max(point.y, radius), max(radius, size.height - radius))
        )
    }
}
#endif
