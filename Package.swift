// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ensemble",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-updates. Pinned exactly; bump deliberately (see docs/RELEASING.md).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Pure logic: gesture rules, gesture state machine, nose pointer. No camera, no UI, unit-tested.
        .target(name: "EnsembleCore", path: "Sources/EnsembleCore", exclude: ["Vendor/Sleight/LICENSE-sleight", "Vendor/LICENSE-claude-dictation-hotkey"]),
        // The menu-bar app.
        .executableTarget(
            name: "Ensemble",
            dependencies: ["EnsembleCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Ensemble",
            // The web folder is copied by scripts/bundle.sh, not declared as a SwiftPM resource: SwiftPM's generated
            // resource accessor embeds the build machine's absolute path (its home folder and user name) in the binary.
            exclude: ["Info.plist", "Ensemble.entitlements", "Resources"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/Ensemble/Info.plist",
                    // scripts/bundle.sh embeds Sparkle.framework in Contents/Frameworks.
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(name: "EnsembleCoreTests", dependencies: ["EnsembleCore"], path: "Tests/EnsembleCoreTests", resources: [.copy("Fixtures")]),
    ]
)
