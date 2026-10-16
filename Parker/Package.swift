// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Parker",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.1"),
    ],
    targets: [
        .executableTarget(
            name: "Parker",
            dependencies: ["HotKey", "ThinkingOrbsKit", "BorderBeamKit"],
            path: "Sources"
        ),
        // SwiftUI ports of libraries.dev (MIT, github.com/Jakubantalik/Libraries.dev), vendored.
        // BorderBeamKit's Metal shaders live in Shaders/ and are compiled by build-app.sh.
        .target(name: "ThinkingOrbsKit", path: "Vendor/ThinkingOrbsKit"),
        .target(name: "BorderBeamKit", path: "Vendor/BorderBeamKit"),
    ]
)
