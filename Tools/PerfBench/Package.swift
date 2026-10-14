// swift-tools-version:5.9
import PackageDescription

// Standalone micro-benchmarks for Clutch's per-frame costs. Not part of the app package; uses a synthetic image, never the camera.
let package = Package(
    name: "PerfBench",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "perfbench", path: "Sources/perfbench")]
)
