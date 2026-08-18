// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SousKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
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
