// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PinSnapKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "PinSnapKit", targets: ["PinSnapKit"]),
    ],
    targets: [
        .target(
            name: "PinSnapKit",
            path: "Sources/PinSnap",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("StoreKit"),
                .linkedFramework("Vision"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "PinSnapKitTests",
            dependencies: ["PinSnapKit"],
            path: "Tests/PinSnapTests"
        ),
    ]
)
