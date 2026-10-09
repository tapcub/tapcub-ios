// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TapCub",
    platforms: [.iOS(.v13), .macOS(.v11), .tvOS(.v13)],
    products: [
        .library(name: "TapCub", targets: ["TapCub"]),
    ],
    targets: [
        .target(name: "TapCubCore", path: "Sources/TapCubCore"),
        .target(name: "TapCubCrashC", path: "Sources/TapCubCrashC"),
        .target(
            name: "TapCub",
            dependencies: ["TapCubCore", "TapCubCrashC"],
            path: "Sources/TapCub",
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "TapCubCoreTests", dependencies: ["TapCubCore"], path: "Tests/TapCubCoreTests"),
        .testTarget(name: "TapCubTests", dependencies: ["TapCub"], path: "Tests/TapCubTests"),
    ]
)
