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
//   otherwise             — the real tool, in every build configuration
//
// The lens no longer keys off `DEBUG`. Release and "shipping to the App Store"
// are not the same thing: a team handing TestFlight builds to QA needs the lens
// in a Release configuration, and configuration-sniffing kept that team fighting
// the framework. Real by default, opt out per target with NETWORKLENS_DISABLED.
//
// Two consequences, stated plainly. Every configuration that omits the flag —
// including an App Store archive — links and runs the real interceptor, so an
// app that must not ship it defines NETWORKLENS_DISABLED in that configuration.
// And this links both modules and compiles one away; the dead one is stripped by
// the linker in practice, but if your release binary must provably not contain
// the tool, link `NetworkLensNoOp` directly instead of this umbrella. See the README.

#if NETWORKLENS_DISABLED
@_exported import NetworkLensNoOp
#else
@_exported import NetworkLensUI
#endif
