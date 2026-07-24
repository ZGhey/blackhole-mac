// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BlackHoleApp",
    platforms: [.macOS(.v13)],
    targets: [
        // SwiftPM has no build rule for .metal in an executableTarget, so the
        // shader ships as a plain resource and Renderer compiles it at launch
        // (~200 ms once). That also makes "Reload shader" possible without a
        // rebuild — see Renderer.makeLibrary.
        .executableTarget(
            name: "BlackHoleApp",
            path: "Sources/BlackHoleApp",
            resources: [.copy("BlackHole.metal")]
        )
    ]
)
