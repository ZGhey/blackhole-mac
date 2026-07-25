// Render the README's demo: every style in turn, over a still of a real screen.
//
//   swift run render-demo <BlackHole.metal> <backdrop.png> <outdir>
//
// Offscreen rather than screen-recorded, for the same reasons make-icon.sh is:
// it needs no permission and no tidy desktop, every frame is exactly placed, and
// running it again produces the same file. What it costs is that the compositing
// the window server normally does has to be done here — the shader emits
// premultiplied alpha over nothing, so the backdrop crop is composited under it
// by hand.
import AppKit
import BlackHoleCore
import Metal

let shaderPath = CommandLine.arguments[1]
let backdropPath = CommandLine.arguments[2]
let outDir = CommandLine.arguments[3]

/// Frame size, rate, and how long each style is on screen. A GIF pays for every
/// one of these twice — pixels times frames — and a README wants a few
/// megabytes, not fifteen. Overridable so tuning does not need a rebuild.
func env(_ name: String, _ fallback: Double) -> Double {
    ProcessInfo.processInfo.environment[name].flatMap(Double.init) ?? fallback
}
let S = Int(env("DEMO_SIZE", 360))
let FPS = Int(env("DEMO_FPS", 12))
let SECONDS = env("DEMO_SECONDS", 1.6)
let framesPerStyle = Int(Double(FPS) * SECONDS)

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let library = try device.makeLibrary(source: String(contentsOfFile: shaderPath, encoding: .utf8),
                                     options: nil)
let pd = MTLRenderPipelineDescriptor()
pd.vertexFunction = library.makeFunction(name: "blackholeVertex")!
pd.fragmentFunction = library.makeFunction(name: "blackholeFragment")!
for i in 0..<2 {
    let a = pd.colorAttachments[i]!
    a.pixelFormat = .bgra8Unorm
    a.isBlendingEnabled = i == 0
    a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
    a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
    a.destinationRGBBlendFactor = .oneMinusSourceAlpha
    a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
}
let pipeline = try device.makeRenderPipelineState(descriptor: pd)

// ------------------------------------------------------------- backdrop --

/// The screen still, as BGRA bytes and as a mipmapped texture. Mipmapped for
/// the same reason the app does it: the lens compresses a wide band of it into
/// a few pixels, and a single level is exactly what makes that alias.
func loadBackdrop() -> (texture: MTLTexture, pixels: [UInt8], width: Int, height: Int) {
    guard let image = NSImage(contentsOfFile: backdropPath),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { fatalError("could not read \(backdropPath)") }
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue)!
    // No transform. `CGContext.draw` puts the image's first row at the top of
    // the destination rect whatever way the context counts, so the buffer comes
    // out top-down — which is what the Metal texture wants and what the shader's
    // uv assumes. Flipping here to "correct" for the bottom-left origin is the
    // mistake: it hands the shader a mirrored screen, and since the widget was
    // then drawn mirrored too, the two cancelled and only the hole came out
    // upside down.
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                     width: w, height: h, mipmapped: true)
    d.usage = .shaderRead
    let t = device.makeTexture(descriptor: d)!
    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
    let cb = queue.makeCommandBuffer()!
    let b = cb.makeBlitCommandEncoder()!
    b.generateMipmaps(for: t); b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return (t, px, w, h)
}
let backdrop = loadBackdrop()

/// Where on the backdrop the widget sits. Centred, and a comfortable fraction of
/// the shorter side — roughly what "Medium" looks like on a laptop screen.
let side = Double(min(backdrop.width, backdrop.height)) * 0.62
let cropRect = CGRect(x: (Double(backdrop.width) - side) / 2,
                      y: (Double(backdrop.height) - side) / 2,
                      width: side, height: side)
// The shader's uv and the texture both run top-down, and so does this crop, so
// the y flip screenRect does for AppKit window frames is undone here.
let fit = BackgroundFit(
    scaleX: Float(cropRect.width / Double(backdrop.width)),
    scaleY: Float(cropRect.height / Double(backdrop.height)),
    offX: Float(cropRect.minX / Double(backdrop.width)),
    offY: Float(cropRect.minY / Double(backdrop.height)))

let sampler: MTLSamplerState = {
    let d = MTLSamplerDescriptor()
    d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
    d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge
    d.maxAnisotropy = 8
    return device.makeSamplerState(descriptor: d)!
}()
let blank: MTLTexture = {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                     width: 1, height: 1, mipmapped: false)
    d.usage = .shaderRead
    return device.makeTexture(descriptor: d)!
}()

// ---------------------------------------------------------------- motion --

/// The same integration `Renderer.draw` performs, duplicated deliberately: this
/// is a build-time tool and pulling the render loop apart to share six lines
/// would put the shipping app at risk for a picture. If the app's motion
/// changes, change it here too — the demo is meant to look like the app.
struct Motion {
    var diskPhase: Float = 0
    var driftClock: Float = 0

    mutating func advance(_ dt: Float, _ t: Tunables) {
        diskPhase += dt * Float(abs(t["DISK_SPEED"]) * t["DISK_RATE"])
        driftClock += dt * Float(t["DRIFT_SPEED"])
    }

    func drift(_ t: Tunables) -> SIMD2<Float> {
        let amp = Float(t["DRIFT"])
        let k = driftClock * 0.25
        return SIMD2<Float>(amp * (0.75 * sin(k * 0.37) + 0.25 * sin(k * 0.83 + 1.0)),
                            amp * (0.70 * sin(k * 0.54 + 2.1) + 0.30 * sin(k * 1.07)))
    }
}

// ----------------------------------------------------------------- frames --

/// One frame of the widget alone, premultiplied, transparent where the hole
/// does not reach.
func renderWidget(_ t: Tunables, _ motion: Motion) -> [UInt8] {
    var u = FrameUniforms.make(t, FrameInputs(
        time: motion.driftClock, diskPhase: motion.diskPhase,
        width: Float(S), height: Float(S),
        bgFit: fit, skyAlpha: 1, drift: motion.drift(t),
        nSteps: Float(t["N_STEPS"])))

    let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                      width: S, height: S, mipmapped: false)
    od.usage = [.renderTarget, .shaderRead]; od.storageMode = .shared
    let out = device.makeTexture(descriptor: od)!, emission = device.makeTexture(descriptor: od)!
    let rp = MTLRenderPassDescriptor()
    for (i, target) in [out, emission].enumerated() {
        rp.colorAttachments[i].texture = target
        rp.colorAttachments[i].loadAction = .clear
        rp.colorAttachments[i].storeAction = .store
        rp.colorAttachments[i].clearColor = MTLClearColorMake(0, 0, 0, 0)
    }
    let cb = queue.makeCommandBuffer()!
    let e = cb.makeRenderCommandEncoder(descriptor: rp)!
    e.setRenderPipelineState(pipeline)
    e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
    e.setFragmentTexture(backdrop.texture, index: 0)
    e.setFragmentTexture(blank, index: 1)
    e.setFragmentSamplerState(sampler, index: 0)
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()

    var px = [UInt8](repeating: 0, count: S * S * 4)
    out.getBytes(&px, bytesPerRow: S * 4, from: MTLRegionMake2D(0, 0, S, S), mipmapLevel: 0)
    return px
}

/// The crop of the backdrop the widget covers, scaled to the frame, as the
/// bottom layer. Drawn once — it never moves.
let backdropLayer: CGImage = {
    let full = CGImage(width: backdrop.width, height: backdrop.height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: backdrop.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: CGDataProvider(data: Data(backdrop.pixels) as CFData)!,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    return full.cropping(to: cropRect)!
}()

let labelFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)

/// Composite: backdrop crop, the widget over it, the style's name in the corner.
func compose(_ widget: [UInt8], label: String) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(backdropLayer, in: CGRect(x: 0, y: 0, width: S, height: S))

    var wp = widget
    let over = CGImage(width: S, height: S, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: S * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: CGDataProvider(data: Data(wp) as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    wp.removeAll()
    // Straight in, exactly as render-icon draws the same read-back buffer. That
    // tool's output is the shipped app icon, so it is the orientation to match.
    ctx.draw(over, in: CGRect(x: 0, y: 0, width: S, height: S))

    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    let text = NSAttributedString(string: label, attributes: [
        .font: labelFont,
        .foregroundColor: NSColor(white: 1, alpha: 0.85),
        // A shadow rather than a plate: the backdrop is arbitrary, and a box
        // would cover the very thing the picture is about.
        .shadow: {
            let s = NSShadow()
            s.shadowColor = NSColor(white: 0, alpha: 0.9)
            s.shadowBlurRadius = 4
            return s
        }(),
    ])
    text.draw(at: NSPoint(x: 18, y: 16))
    NSGraphicsContext.restoreGraphicsState()

    return ctx.makeImage()!
}

func write(_ cg: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let dt = Float(1.0 / Double(FPS))
var index = 0
for (name, patch) in Specs.styles {
    let t = Tunables().applying(patch)
    // Each style starts already turning rather than from a standstill, so the
    // cut between them does not read as a stutter.
    var motion = Motion(diskPhase: 3, driftClock: 7)
    for _ in 0..<framesPerStyle {
        write(compose(renderWidget(t, motion), label: name),
              String(format: "%@/frame-%04d.png", outDir, index))
        motion.advance(dt, t)
        index += 1
    }
    print("  \(name): \(framesPerStyle) frames")
}
print("wrote \(index) frames to \(outDir) at \(S)x\(S), \(FPS) fps")
