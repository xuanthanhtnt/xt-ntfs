// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XTNTFS",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "XTNTFS", targets: ["XTNTFS"]),
        .executable(name: "xtntfsd", targets: ["xtntfsd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        // Models, wire protocol and paths shared by the app and the helper.
        .target(
            name: "XTShared",
            path: "Sources/XTShared"
        ),
        // Privileged LaunchDaemon: watches disks, blocks the read-only
        // system mount for NTFS volumes and mounts them with the XT engine.
        .executableTarget(
            name: "xtntfsd",
            dependencies: ["XTShared"],
            path: "Sources/xtntfsd",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        // The SwiftUI application.
        .executableTarget(
            name: "XTNTFS",
            dependencies: [
                "XTShared",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/XTNTFS",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "XTSharedTests",
            dependencies: ["XTShared"],
            path: "Tests/XTSharedTests"
        ),
    ]
)
