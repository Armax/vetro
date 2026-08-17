// swift-tools-version:6.1
import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Vetro",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Vetro", targets: ["Vetro"]),
        .library(name: "VMKit", targets: ["VMKit"]),
    ],
    targets: [
        .executableTarget(
            name: "Vetro",
            dependencies: ["GhosttyKit", "VMKit"],
            swiftSettings: strictConcurrencySettings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
            ]
        ),
        .target(
            name: "VMKit",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: strictConcurrencySettings,
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Virtualization"),
            ]
        ),
        .executableTarget(
            name: "VetroVMSmoke",
            dependencies: ["VMKit"]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        .testTarget(
            name: "VMKitTests",
            dependencies: ["VMKit"],
            swiftSettings: strictConcurrencySettings
        ),
    ]
)
