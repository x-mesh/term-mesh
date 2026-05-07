// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PeerProto",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PeerProto", targets: ["PeerProto"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.29.0")
    ],
    targets: [
        .target(
            name: "PeerProto",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "Sources/PeerProto"
        ),
        .testTarget(
            name: "PeerProtoTests",
            dependencies: ["PeerProto"],
            path: "Tests/PeerProtoTests"
        )
    ]
)
