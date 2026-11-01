// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TobiCore",
    // 文字列で書く（tools-version 6.0 には対応する .vNN の定数がないため）
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "TobiCore", targets: ["TobiCore"])
    ],
    targets: [
        .target(name: "TobiCore"),
        .testTarget(name: "TobiCoreTests", dependencies: ["TobiCore"]),
    ]
)
