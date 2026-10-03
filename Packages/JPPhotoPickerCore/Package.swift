// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JPPhotoPickerCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "JPPhotoPickerCore", targets: ["JPPhotoPickerCore"]),
    ],
    targets: [
        .target(name: "JPPhotoPickerCore"),
        .testTarget(name: "JPPhotoPickerCoreTests", dependencies: ["JPPhotoPickerCore"]),
    ]
)
