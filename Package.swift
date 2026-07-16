// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cclimit",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "CClimitCore"),
        .target(name: "CClimitUI", dependencies: ["CClimitCore"]),
        .executableTarget(
            name: "CClimit",
            dependencies: [
                "CClimitCore",
                "CClimitUI",
                .product(name: "Sparkle", package: "Sparkle"),
            ]),
        .executableTarget(name: "cclimit-dump", dependencies: ["CClimitCore"]),
        .testTarget(name: "CClimitCoreTests", dependencies: ["CClimitCore"]),
        .testTarget(name: "CClimitUITests", dependencies: ["CClimitCore", "CClimitUI"]),
    ]
)
