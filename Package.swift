// swift-tools-version: 6.0

import Foundation
import PackageDescription

// The iPad's GPU for containers needs ggml (gpu/build-ggml.sh) and the
// backend containers load (gpu/build-shim.sh); without them Pier builds
// without the GPU.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }
let hasGPU = exists("Frameworks/ggml.xcframework") && exists("Sources/PierCore/Resources/libggml-rpc.so")
let gpuTargets: [Target] = hasGPU ? [.binaryTarget(name: "ggml", path: "Frameworks/ggml.xcframework")] : []
let gpuDependencies: [Target.Dependency] = hasGPU ? ["ggml"] : []
let gpuResources: [Resource] = hasGPU ? [.copy("Resources/libggml-rpc.so")] : []

let package = Package(
    name: "pier",
    platforms: [.macOS("15.0"), .iOS("26.0")],
    products: [
        .library(name: "PierCore", targets: ["PierCore"]),
    ],
    dependencies: [
        // apple/containerization with the crate backend (branch `crate`).
        .package(path: "../containerization"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.10.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/jpsim/Yams.git", "5.1.0"..<"7.0.0"),
    ],
    targets: gpuTargets + [
        .target(
            name: "PierCore",
            dependencies: gpuDependencies + [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [.copy("Resources/cacert.pem"), .copy("Resources/vmexec-overlay.tar.gz")] + gpuResources
        ),
        .testTarget(
            name: "PierCoreTests",
            dependencies: ["PierCore"]
        ),
        .executableTarget(
            name: "pierctl",
            dependencies: [
                "PierCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
