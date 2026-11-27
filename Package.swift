// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NanoPanda",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NanoPandaCore", targets: ["NanoPandaCore"]),
        .executable(name: "NanoPanda", targets: ["NanoPandaApp"])
    ],
    targets: [
        .target(name: "NanoPandaCore"),
        .executableTarget(name: "NanoPandaApp", dependencies: ["NanoPandaCore"]),
        .testTarget(name: "NanoPandaCoreTests", dependencies: ["NanoPandaCore"])
    ]
)
