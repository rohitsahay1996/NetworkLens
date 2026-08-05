//
//  NetworkLens.swift
//  NetworkLens
//
//  Created by Rohit Sahay on 31/07/26.
//

// Umbrella module. Host code writes `import NetworkLens` once and never edits
// that line again — which build it gets is a build setting, not a source
// change.
//
// Without this, swapping the tool out for release means editing every file that
// imports it, in an app where those files are spread across a networking module,
// an app target and a debug menu. That edit gets forgotten, and the first person
// to notice is a reviewer looking at a shipped binary.
//
// Resolution order, most explicit first:
//
//   NETWORKLENS_DISABLED  — force the inert mirror, whatever the configuration
//   NETWORKLENS_ENABLED   — force the real tool, e.g. for a Release TestFlight
//                           build a QA team is using
//   DEBUG                 — the default: real in Debug, inert in Release
//
// Both flags exist because "Release" and "shipping to the App Store" are not
// the same thing. A team that hands TestFlight builds to QA needs the lens in a
// Release configuration, and a team with a debug-only build that must never
// carry it needs the opposite.
//
// One caveat, stated plainly: this links both modules and compiles one away.
// The dead one is stripped by the linker in practice, but if your release build
// must provably not contain the tool, link `NetworkLensNoOp` directly instead of
// this umbrella and skip the flag entirely. See the README.

#if NETWORKLENS_DISABLED
@_exported import NetworkLensNoOp
#elseif NETWORKLENS_ENABLED
@_exported import NetworkLensUI
#elseif DEBUG
@_exported import NetworkLensUI
#else
@_exported import NetworkLensNoOp
#endif
