// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetworkLens",
    // macOS is listed so `swift test` can drive NetworkLensCore headlessly in CI,
    // with no simulator and no host app. Core must never require UIKit.
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        // What an app should link. Resolves to the real tool or the inert
        // mirror by build configuration, so `import NetworkLens` is written
        // once and never edited again.
        .library(name: "NetworkLens", targets: ["NetworkLens"]),
        // Linked directly by teams that need the release binary to provably
        // contain nothing, and by anyone wiring the pieces themselves.
        .library(name: "NetworkLensCore", targets: ["NetworkLensCore"]),
        .library(name: "NetworkLensUI", targets: ["NetworkLensUI"]),
        .library(name: "NetworkLensNoOp", targets: ["NetworkLensNoOp"]),
    ],
    targets: [
        .target(name: "NetworkLens", dependencies: ["NetworkLensUI", "NetworkLensNoOp"]),
        .target(name: "NetworkLensCore"),
        .target(name: "NetworkLensUI", dependencies: ["NetworkLensCore"]),
        .target(name: "NetworkLensNoOp"),
        .testTarget(
            name: "NetworkLensCoreTests",
            dependencies: ["NetworkLensCore"],
            // Real bytes captured off the sidecar, so the MCP server and the
            // control channel's decoder cannot drift apart without a test
            // going red.
            resources: [.copy("Fixtures")]),
        // Compiles the README's UIKit lifecycle code. Empty on macOS, which is
        // the point: these are the snippets `swift test` can never check, so
        // they need an iOS simulator destination to mean anything.
        .testTarget(name: "NetworkLensUITests", dependencies: ["NetworkLensUI"]),
        // Compiles host-shaped call sites against the inert mirror. Its job is
        // to fail the build when Core grows API that NoOp did not, which is
        // otherwise only discovered by a release build months later.
        .testTarget(name: "NetworkLensNoOpTests", dependencies: ["NetworkLensNoOp"]),
    ]
)
