// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppMixer",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "MixerDSP"),
        .executableTarget(name: "AppMixer", dependencies: ["MixerDSP"]),
        .testTarget(name: "MixerDSPTests", dependencies: ["MixerDSP"])
    ]
)
