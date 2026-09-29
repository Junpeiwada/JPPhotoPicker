// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PhotoPickerCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PhotoPickerCore", targets: ["PhotoPickerCore"]),
    ],
    targets: [
        .target(name: "PhotoPickerCore"),
        .testTarget(name: "PhotoPickerCoreTests", dependencies: ["PhotoPickerCore"]),
    ]
)
