// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clutch",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: gesture rules, gesture state machine, nose pointer. No camera, no UI, unit-tested.
        .target(name: "ClutchCore", path: "Sources/ClutchCore", exclude: ["Vendor/Sleight/LICENSE-sleight", "Vendor/LICENSE-claude-dictation-hotkey"]),
        // The menu-bar app.
        .executableTarget(
            name: "Clutch",
            dependencies: ["ClutchCore"],
            path: "Sources/Clutch",
            exclude: ["Info.plist"],
            resources: [.copy("Resources/web")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/Clutch/Info.plist"])
            ]
        ),
        .testTarget(name: "ClutchCoreTests", dependencies: ["ClutchCore"], path: "Tests/ClutchCoreTests", resources: [.copy("Fixtures")]),
    ]
)
