//
//  Overlay.swift
//  NetworkLensNoOp
//
//  Created by Rohit Sahay on 05/08/26.
//

// The SwiftUI half of the mirror. `NetworkLensUI` puts `networkLensOverlay()`
// on `View`, so a SwiftUI app writes it once in its scene body — and a release
// build has to compile that same line with nothing behind it.
//
// Kept in its own file because it is the only part of the mirror that needs
// SwiftUI, and NetworkLensNoOp is meant to stay importable anywhere the real
// module is.

#if canImport(UIKit)
import SwiftUI

extension View {

    /// Inert mirror of the overlay modifier: returns the view untouched.
    public func networkLensOverlay() -> some View { self }
}
#endif
