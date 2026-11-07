// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "INAVServoSupport",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "INAVServoSupport", targets: ["INAVServoSupport"])
    ],
    targets: [
        .executableTarget(
            name: "INAVServoSupport",
            path: "Sources/INAVServoSupport",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
