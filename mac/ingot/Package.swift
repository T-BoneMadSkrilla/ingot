// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Ingot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Ingot", path: "Sources/Ingot")
    ]
)
