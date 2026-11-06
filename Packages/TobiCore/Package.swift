// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TobiCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TobiCore", targets: ["TobiCore"])
    ],
    targets: [
        .target(name: "TobiCore"),
        .testTarget(name: "TobiCoreTests", dependencies: ["TobiCore"]),
    ]
)
