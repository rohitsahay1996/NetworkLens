// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetworkLens",
    // macOS is listed so `swift test` can drive NetworkLensCore headlessly in CI,
    // with no simulator and no host app. Core must never require UIKit.
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "NetworkLensCore", targets: ["NetworkLensCore"]),
        .library(name: "NetworkLensUI", targets: ["NetworkLensUI"]),
        .library(name: "NetworkLensNoOp", targets: ["NetworkLensNoOp"]),
    ],
    targets: [
        .target(name: "NetworkLensCore"),
        .target(name: "NetworkLensUI", dependencies: ["NetworkLensCore"]),
        .target(name: "NetworkLensNoOp"),
        .testTarget(name: "NetworkLensCoreTests", dependencies: ["NetworkLensCore"]),
    ]
)
