// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GigCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "GigCore", targets: ["GigCore"])],
    targets: [
        .target(name: "GigCore"),
        .testTarget(name: "GigCoreTests", dependencies: ["GigCore"]),
    ]
)
