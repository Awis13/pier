// swift-tools-version: 6.0

import PackageDescription

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
    targets: [
        // ggml with Metal and its RPC server, from llama.cpp (gpu/build-ggml.sh).
        .binaryTarget(name: "ggml", path: "Frameworks/ggml.xcframework"),
        .target(
            name: "PierCore",
            dependencies: [
                "ggml",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [.copy("Resources/cacert.pem"), .copy("Resources/vmexec-overlay.tar.gz"), .copy("Resources/libggml-rpc.so")]
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
