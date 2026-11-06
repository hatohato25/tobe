// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TobeCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TobeCore", targets: ["TobeCore"])
    ],
    targets: [
        .target(name: "TobeCore"),
        .testTarget(name: "TobeCoreTests", dependencies: ["TobeCore"]),
    ]
)
