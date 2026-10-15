// swift-tools-version:5.9
import PackageDescription

// Standalone micro-benchmarks for Ensemble's per-frame costs. Not part of the app package; uses a synthetic image or a synthetic head path, never the camera.
let package = Package(
    name: "PerfBench",
    platforms: [.macOS(.v14)],
    // The pointer replay runs the app's own filter and dot code.
    dependencies: [.package(name: "Ensemble", path: "../..")],
    targets: [.executableTarget(name: "perfbench", dependencies: [.product(name: "EnsembleCore", package: "Ensemble")], path: "Sources/perfbench")]
)
