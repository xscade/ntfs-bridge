// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NTFSBridge",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NTFSBridgeCore", targets: ["NTFSBridgeCore"]),
        .executable(name: "ntfsb", targets: ["ntfsb"]),
    ],
    targets: [
        .target(name: "NTFSBridgeCore"),
        .executableTarget(name: "ntfsb", dependencies: ["NTFSBridgeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
