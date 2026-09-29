// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SousKit",
    platforms: [.iOS("27.0"), .macOS("26.5")],
    products: [
        .library(name: "SousKit", targets: ["SousKit"])
    ],
    targets: [
        .target(name: "SousKit", resources: [.process("Resources")]),
        .testTarget(
            name: "SousKitTests",
            dependencies: ["SousKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
