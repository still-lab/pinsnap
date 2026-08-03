// swift-tools-version: 5.9
import PackageDescription

/// 规划期以 Swift Package 承载接口骨架；M0 迁入 Xcode macOS App Target。
let package = Package(
    name: "PinSnap",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "PinSnap", targets: ["PinSnap"]),
    ],
    targets: [
        .target(
            name: "PinSnap",
            path: "Sources/PinSnap"
        ),
        .testTarget(
            name: "PinSnapTests",
            dependencies: ["PinSnap"],
            path: "Tests/PinSnapTests"
        ),
    ]
)
