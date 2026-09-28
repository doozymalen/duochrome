// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Duochrome",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Duochrome", path: "Sources/Duochrome")]
)
