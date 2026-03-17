// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "term-mesh",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "term-mesh", targets: ["term-mesh"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "term-mesh",
            dependencies: ["SwiftTerm"],
            path: "Sources"
        )
    ]
)
