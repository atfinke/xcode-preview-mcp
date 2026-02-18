// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xcode-preview-helper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "xcode-preview-helper",
            targets: ["XcodePreviewHelper"]
        )
    ],
    targets: [
        .executableTarget(
            name: "XcodePreviewHelper"
        )
    ]
)
