//
//  LensHeaders.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 31/07/26.
//

import Foundation

/// Headers the lens reads off a request and then removes.
///
/// The zero-dependency seam. In most teams the networking code lives in its own
/// module — `CoreNetwork` or similar — that the app imports, and that module
/// has no business importing a debugging tool: it would drag the dependency
/// into every consumer, including the ones that ship.
///
/// So attribution can also arrive as a header. A networking module sets a
/// string it already has, on a request it already builds, using API it already
/// uses. Nothing links, nothing is conditionally compiled, and deleting the
/// lens leaves a header nobody reads.
///
/// The header never reaches the network: `LensURLProtocol` strips it before the
/// request goes out, so a backend never sees it even if the tool is left on in
/// a build that talks to production.
public enum LensHeaders {

    /// Screen that fired the request — the same value `ScreenContext` and
    /// `NetworkLens.tagged(_:screen:)` supply.
    ///
    /// ```swift
    /// request.setValue("Checkout", forHTTPHeaderField: LensHeaders.screen)
    /// ```
    public static let screen = "X-NetworkLens-Screen"

    /// Every header the lens claims, for stripping in one pass.
    static let all = [screen]
}

extension URLRequest {

    /// The screen this request names, if any.
    func lensScreenHeader() -> String? {
        value(forHTTPHeaderField: LensHeaders.screen)
    }

    /// The same request with the lens's own headers removed.
    ///
    /// Applied to what actually goes out *and* to what is captured: a header
    /// the app never really sent would be a lie in a bug report, and a curl
    /// command carrying it would fail to reproduce anything.
    func strippingLensHeaders() -> URLRequest {
        guard let fields = allHTTPHeaderFields,
              LensHeaders.all.contains(where: { fields[$0] != nil })
        else { return self }

        var copy = self
        for header in LensHeaders.all {
            copy.setValue(nil, forHTTPHeaderField: header)
        }
        return copy
    }
}
