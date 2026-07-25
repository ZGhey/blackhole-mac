// Renders the app's own icons with the app's own renderer.
//
// There is no icon art in this repo and there does not need to be: the thing
// the app draws is the thing the icon should be. This runs BlackHole.metal
// offscreen and writes the PNGs that make-icon.sh turns into AppIcon.icns and
// the menu-bar template.
//
//   swift Tools/render-icon.swift <BlackHole.metal> <outdir>
//
// The app icon gets a dark rounded square behind it, because that is what a
// macOS icon is; the menu-bar image is the render's own luminance used as an
// alpha mask, marked as a template so the system tints it.
import AppKit
import Metal

let shaderPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let library = try device.makeLibrary(source: String(contentsOfFile: shaderPath, encoding: .utf8),
                                     options: nil)
let pd = MTLRenderPipelineDescriptor()
pd.vertexFunction = library.makeFunction(name: "blackholeVertex")!
pd.fragmentFunction = library.makeFunction(name: "blackholeFragment")!
for i in 0..<2 {
    let a = pd.colorAttachments[i]!
    a.pixelFormat = .rgba8Unorm
    a.isBlendingEnabled = i == 0
    a.rgbBlendOperation = .add
    a.alphaBlendOperation = .add
    a.sourceRGBBlendFactor = .one            // the shader emits premultiplied
    a.sourceAlphaBlendFactor = .one
    a.destinationRGBBlendFactor = .oneMinusSourceAlpha
    a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
}
let pipeline = try device.makeRenderPipelineState(descriptor: pd)

/// A 1x1 stand-in for the screen capture. The icon has no screen behind it, so
/// the lens has nothing to bend and the starfield does the work instead.
let blank: MTLTexture = {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                     width: 1, height: 1, mipmapped: false)
    d.usage = .shaderRead
    let t = device.makeTexture(descriptor: d)!
    var px: [UInt8] = [0, 0, 0, 255]
    t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
    return t
}()
let sampler: MTLSamplerState = {
    let d = MTLSamplerDescriptor()
    d.minFilter = .linear; d.magFilter = .linear
    d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge
    return device.makeSamplerState(descriptor: d)!
}()

/// The Inferno preset, with the hole opened up and the starfield turned on —
/// at 16 pt a widget-proportioned composition is a grey smudge, so the icon
/// trades halo for ring. `skyAlpha` 0 keeps the corners transparent.
func uniforms(size: Int, halo: Float, stars: Float) -> [Float] {
    [
        6.0, Float(size), Float(size), halo,
        13, 2.0, stars, 6.0,
        1.8, 8, 1.30, 0.35,
        2.4, 0.9, 5500, 0.6,
        2.5, 5, 7, 1.7,
        1.5, 0, 96, 1,
        1, 1, 0, 0,
        /*skyAlpha*/ 0, 0, 1.6, 2.4,
        0, 0, 1, 1.6,
        0, 0, 0, 0,
        0, 0, 0, 0,
        1, 1, 1, 0.55,
        0, 26, 0, 0,
    ]
}

func render(size: Int, halo: Float, stars: Float) -> [UInt8] {
    var u = uniforms(size: size, halo: halo, stars: stars)
    let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                      width: size, height: size, mipmapped: false)
    od.usage = [.renderTarget, .shaderRead]
    od.storageMode = .shared
    let out = device.makeTexture(descriptor: od)!
    let emission = device.makeTexture(descriptor: od)!
    let rp = MTLRenderPassDescriptor()
    for (i, t) in [out, emission].enumerated() {
        rp.colorAttachments[i].texture = t
        rp.colorAttachments[i].loadAction = .clear
        rp.colorAttachments[i].storeAction = .store
        rp.colorAttachments[i].clearColor = MTLClearColorMake(0, 0, 0, 0)
    }
    let cb = queue.makeCommandBuffer()!
    let e = cb.makeRenderCommandEncoder(descriptor: rp)!
    e.setRenderPipelineState(pipeline)
    e.setFragmentBytes(&u, length: MemoryLayout<Float>.stride * u.count, index: 0)
    e.setFragmentTexture(blank, index: 0)
    e.setFragmentTexture(blank, index: 1)
    e.setFragmentSamplerState(sampler, index: 0)
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    e.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    var px = [UInt8](repeating: 0, count: size * size * 4)
    out.getBytes(&px, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
    return px   // premultiplied RGBA
}

func image(_ px: [UInt8], _ size: Int) -> CGImage {
    var p = px
    let ctx = CGContext(data: &p, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

func write(_ cg: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

// ------------------------------------------------------------- app icon --
// macOS icons live on a rounded square with a margin, and the system expects
// that shape — a free-form sprite reads as a foreign object in the Dock.
func appIcon(_ size: Int) -> CGImage {
    let inset = CGFloat(size) * 0.09          // Apple's grid leaves a margin
    let side = CGFloat(size) - inset * 2
    let radius = side * 0.225                 // the squircle's corner
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    let plate = CGRect(x: inset, y: inset, width: side, height: side)
    let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    // Deep space, slightly lifted at the bottom so the plate has a direction.
    let grad = CGGradient(colorsSpace: cs,
                          colors: [CGColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1),
                                   CGColor(red: 0.10, green: 0.09, blue: 0.13, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: plate.maxY),
                           end: CGPoint(x: 0, y: plate.minY), options: [])
    // The hole, rendered big enough that the ring survives 16 px.
    let px = render(size: size * 2, halo: 1.0, stars: 0.9)
    ctx.interpolationQuality = .high
    // Exactly the plate: overflowing it clipped the disk against the
    // rounded corner on the side the roll throws it toward.
    ctx.draw(image(px, size * 2), in: plate)
    return ctx.makeImage()!
}

let fm = FileManager.default
let iconset = outDir + "/AppIcon.iconset"
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                   (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                   (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    write(appIcon(px), "\(iconset)/icon_\(name).png")
}
print("wrote \(iconset)")

// -------------------------------------------------------- menu bar icon --
// A template image: only alpha matters, the system paints it black or white to
// match the menu bar. Using the render's own luminance as that alpha keeps the
// silhouette honest — bright disk opaque, shadow cut out of the middle.
func menuIcon(_ size: Int) -> CGImage {
    let px = render(size: size * 8, halo: 1.0, stars: 0)
    let big = size * 8
    var alpha = [UInt8](repeating: 0, count: big * big * 4)
    for i in stride(from: 0, to: big * big * 4, by: 4) {
        let r = Double(px[i]), g = Double(px[i+1]), b = Double(px[i+2])
        // Premultiplied already, so luminance *is* coverage.
        let l = min(1.0, (0.299 * r + 0.587 * g + 0.114 * b) / 255 * 1.35)
        alpha[i] = 0; alpha[i+1] = 0; alpha[i+2] = 0
        alpha[i+3] = UInt8(l * 255)
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    let src = CGContext(data: &alpha, width: big, height: big, bitsPerComponent: 8,
                        bytesPerRow: big * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}
// One file at 36 px; the app sets the NSImage's size to 18 pt, so the same
// data serves 1x and 2x without an asset catalogue.
write(menuIcon(36), outDir + "/MenuIcon.png")
print("wrote \(outDir)/MenuIcon.png")
