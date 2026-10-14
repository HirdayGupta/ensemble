// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clutch",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-updates. Pinned exactly; bump deliberately (see docs/RELEASING.md).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Pure logic: gesture rules, gesture state machine, nose pointer. No camera, no UI, unit-tested.
        .target(name: "ClutchCore", path: "Sources/ClutchCore", exclude: ["Vendor/Sleight/LICENSE-sleight", "Vendor/LICENSE-claude-dictation-hotkey"]),
        // The menu-bar app.
        .executableTarget(
            name: "Clutch",
            dependencies: ["ClutchCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Clutch",
            exclude: ["Info.plist", "Clutch.entitlements"],
            resources: [.copy("Resources/web")],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/Clutch/Info.plist",
                    // scripts/bundle.sh embeds Sparkle.framework in Contents/Frameworks.
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(name: "ClutchCoreTests", dependencies: ["ClutchCore"], path: "Tests/ClutchCoreTests", resources: [.copy("Fixtures")]),
    ]
)
