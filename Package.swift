// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tock",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Tock",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Tock",
            // The app bundle keeps Sparkle.framework in Contents/Frameworks; plain `swift build`
            // binaries (tests, snapshots) find it next to the executable.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
            ])]
        ),
    ]
)
