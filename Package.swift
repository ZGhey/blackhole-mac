// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BlackHoleApp",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything either side of the CPU→GPU seam agrees on: the Uniforms
        // struct, the tunables and their specs, and the one function that fills
        // a Uniforms in. Foundation only — the offscreen tools link it without
        // dragging SwiftUI or AppKit behind them.
        .target(name: "BlackHoleCore", path: "Sources/BlackHoleCore"),

        // SwiftPM has no build rule for .metal in an executableTarget, so the
        // shader ships as a plain resource and Renderer compiles it at launch
        // (~200 ms once). That also makes "Reload shader" possible without a
        // rebuild — see Renderer.makeLibrary.
        .executableTarget(
            name: "BlackHoleApp",
            dependencies: ["BlackHoleCore"],
            path: "Sources/BlackHoleApp",
            resources: [.copy("BlackHole.metal"),
                        .copy("AppIcon.icns"),
                        .copy("MenuIcon.png")]
        ),

        // Both tools drive BlackHole.metal offscreen through the same uniform
        // assembler the app uses. They were single-file scripts that retyped the
        // uniform struct as a positional [Float] array; being targets is what
        // lets them import it instead.
        .executableTarget(
            name: "check-render",
            dependencies: ["BlackHoleCore"],
            path: "Tools/check-render"
        ),
        .executableTarget(
            name: "render-icon",
            dependencies: ["BlackHoleCore"],
            path: "Tools/render-icon"
        ),
    ]
)
