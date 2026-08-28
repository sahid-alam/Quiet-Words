// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "QuietWords",
    platforms: [.macOS("26.0")],
    targets: [
        // Name must stay QuietWords — scripts/bundle.sh reads .build/release/QuietWords.
        .executableTarget(name: "QuietWords", path: "Sources/QuietWords")
    ]
)
