// swift-tools-version:6.0
//
// Fantastic Relay — a relay-KERNEL. Connected kernels become per-connection
// agents; the flat agent registry is the directory, `kernel.send` is the router,
// duplicate-id rejection is GUID-uniqueness. Reuses the canvas kernel as a
// LIBRARY (path dep, never vendored). Dir is `relaykernel/` (not `swift/`) because
// the canvas package's path-dep identity is its basename `swift` — two `swift`
// basenames collide.
import PackageDescription

let package = Package(
    name: "RelayKernel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RelayKernel", targets: ["RelayKernel"]),
        .executable(name: "relayd", targets: ["relayd"]),
        .executable(name: "relay-supervisor", targets: ["relay-supervisor"]),
    ],
    dependencies: [
        // The canvas kernel, reused as a library. Identity = dir basename "swift".
        .package(path: "../../fantastic_canvas/swift"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "RelayKernel",
            dependencies: [
                .product(name: "FantasticKernel", package: "swift"),
                .product(name: "FantasticJSON", package: "swift"),
                .product(name: "FantasticIoBridge", package: "swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "relayd",
            dependencies: ["RelayKernel"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "relay-supervisor",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RelayKernelTests",
            dependencies: [
                "RelayKernel",
                .product(name: "FantasticIoBridge", package: "swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
