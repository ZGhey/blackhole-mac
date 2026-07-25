// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BlackHoleApp",
    // The base language. Everything else is a .lproj beside it, and macOS picks
    // between them from the system's preferred languages — the app has no
    // language setting of its own and should not grow one.
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Sparkle does the part that is easy to get wrong: verifying what was
        // downloaded before it replaces a running app. That signature check is
        // the only thing standing between the update channel and anyone who can
        // put a file where the appcast points.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.5.0"),
    ],
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
            dependencies: ["BlackHoleCore",
                           .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/BlackHoleApp",
            resources: [.copy("BlackHole.metal"),
                        .copy("AppIcon.icns"),
                        .copy("MenuIcon.png"),
                        // .process, not .copy: SwiftPM only treats *.lproj as
                        // localizations when it is processing them.
                        .process("Resources")],
            // Sparkle arrives as an XCFramework, so the built binary has to be
            // able to find it next to itself once make-app.sh has put it in
            // Contents/Frameworks. Under plain `swift run` the loader falls back
            // to the copy in .build, which is why both paths are listed.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath",
                              "-Xlinker", "@executable_path/../Frameworks"]),
            ]
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
