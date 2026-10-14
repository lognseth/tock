// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Tock", path: "Sources/Tock"),
    ]
)
