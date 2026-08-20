// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Switchboard",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Switchboard", targets: ["Switchboard"]),
    ],
    targets: [
        .executableTarget(
            name: "Switchboard",
            path: "Sources/Switchboard",
            exclude: ["Resources", "Helpers"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SwitchboardTests",
            dependencies: ["Switchboard"],
            path: "Tests/SwitchboardTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
