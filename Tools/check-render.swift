// Three measurements, each of which corresponds to a bug that shipped.
//
//   swift Tools/check-render.swift Sources/BlackHoleApp/BlackHole.metal
//
// There is nothing to unit-test in a fragment shader, but there is plenty to
// measure. These are the checks that would have caught the three worst things
// this renderer has done, kept because each one was found the hard way:
//
//   winding    The gas at the inner edge orbits far faster than at the outer
//              edge, so any pattern painted on it winds into an ever-tighter
//              spiral. Left unbounded the filaments went below the pixel grid
//              within two minutes and the disk became a sheet of noise —
//              measured fineness 6.0 at launch, 26.7 after 2 min, 33 after 10.
//              DISK_REFRESH bounds it. This checks it stays bounded.
//   clipping   The bloom threshold sat below the disk's own brightness, so the
//              disk bloomed onto itself and every filament merged into one
//              cream sheet. This checks no style jams itself into the top of
//              the range.
//   aliasing   The sampler never had mipFilter set, so the mip chain built
//              from the capture every frame and the derivatives handed to
//              gradient2d were both dead weight, and the lensed background
//              aliased into crawling moiré. This compares against a 4x
//              supersampled reference.
//
// Prints numbers and exits non-zero if any of them has drifted. The thresholds
// are set well clear of the values as they stand, not at them — this is a trip
// wire, not a golden image.
import AppKit
import Metal

let shaderPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Sources/BlackHoleApp/BlackHole.metal"
let S = 600, TW = 1024

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

/// `dark` is a flat desktop; the other is a page of text, which is the case the
/// lens aliases against.
func background(text: Bool) -> MTLTexture {
    var tx = [UInt8](repeating: 0, count: TW * TW * 4)
    for y in 0..<TW {
        for x in 0..<TW {
            let on = text && (y % 9) < 2 && ((x / 7) % 11) != 0
            let i = (y * TW + x) * 4
            tx[i] = on ? 235 : 22; tx[i+1] = on ? 232 : 20
            tx[i+2] = on ? 228 : 18; tx[i+3] = 255
        }
    }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                     width: TW, height: TW, mipmapped: true)
    d.usage = .shaderRead
    let t = device.makeTexture(descriptor: d)!
    t.replace(region: MTLRegionMake2D(0, 0, TW, TW), mipmapLevel: 0, withBytes: tx, bytesPerRow: TW * 4)
    let cb = queue.makeCommandBuffer()!
    let b = cb.makeBlitCommandEncoder()!
    b.generateMipmaps(for: t); b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return t
}
let darkBG = background(text: false)
let textBG = background(text: true)

/// Matches Renderer's sampler. If this check ever disagrees with what the app
/// builds, the check is the one that is wrong.
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

struct Style { let name: String; let p: [Float] }
// temp, incl, roll, inner, outer, opacity, dopp, beam, gain, contrast, wind, speed, exposure
let styles = [
    Style(name: "Inferno",       p: [5500, 1.50, 0.35, 1.8, 8, 0.90, 0.6, 2.5, 2.2, 1.6, 7, 5, 1.4]),
    Style(name: "Gargantua",     p: [4500, 1.52, 0.10, 2.2, 7, 0.85, 0.35, 2.0, 1.4, 0.5, 7, 5, 1.2]),
    Style(name: "M87* donut",    p: [3800, 0.55, -0.30, 2.2, 6, 0.45, 0.9, 3.5, 1.6, 0.4, 3, 2.5, 1.1]),
    Style(name: "Face-on ember", p: [6500, 0.30, 0.00, 3.0, 10, 0.5, 0.8, 2.5, 1.0, 1.1, 7, 5, 1.0]),
    Style(name: "Quasar",        p: [15000, 1.30, 0.35, 3.0, 14, 0.35, 1.0, 4.0, 1.2, 1.3, 8, 5, 0.8]),
]

func render(_ st: Style, phase: Float, size: Int, bg: MTLTexture, cover: Int,
            bgBlur: Float = 1.5) -> [UInt8] {
    let p = st.p
    var u: [Float] = [
        3.0, Float(size), Float(size), 1.25,
        13, 2.0, 0, phase,
        p[3], p[4], p[1], p[2],
        p[8], p[5], p[0], p[6],
        p[7], p[11], p[10], p[9],
        p[12], 0, 48, 1,
        Float(cover) / Float(TW), Float(cover) / Float(TW), 0.1, 0.1,
        1, 0, 1.8, 2.4,
        0, 0, 1, 1.2,
        0, 0, 0, 0,
        0, 0, 0, 0,
        1, 1, 1, 0.55,
        bgBlur, 26, 0, 0,
    ]
    let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                      width: size, height: size, mipmapped: false)
    od.usage = [.renderTarget, .shaderRead]; od.storageMode = .shared
    let out = device.makeTexture(descriptor: od)!, emission = device.makeTexture(descriptor: od)!
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
    e.setFragmentTexture(bg, index: 0)
    e.setFragmentTexture(blank, index: 1)
    e.setFragmentSamplerState(sampler, index: 0)
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    var px = [UInt8](repeating: 0, count: size * size * 4)
    out.getBytes(&px, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
    return px
}

func luma(_ px: [UInt8], _ size: Int, _ x: Int, _ y: Int) -> Double {
    let i = (y * size + x) * 4
    return 0.299 * Double(px[i+2]) + 0.587 * Double(px[i+1]) + 0.114 * Double(px[i])
}

/// Filament visibility: mean |laplacian| inside the disk, as a percentage of
/// its mean brightness. Falls when structure is lost, whether to bloom, to
/// winding, or to anything else that flattens the gas.
func fineness(_ px: [UInt8], _ size: Int) -> Double {
    var lap = 0.0, lum = 0.0, n = 0
    for y in 1..<(size-1) {
        for x in 1..<(size-1) {
            let l = luma(px, size, x, y)
            guard l > 110 else { continue }
            lap += abs(4*l - luma(px, size, x-1, y) - luma(px, size, x+1, y)
                          - luma(px, size, x, y-1) - luma(px, size, x, y+1))
            lum += l; n += 1
        }
    }
    return n > 0 ? (lap / Double(n)) / (lum / Double(n)) * 100 : 0
}

/// How much of the disk is jammed into the top of the range.
func clipped(_ px: [UInt8], _ size: Int) -> Double {
    var hot = 0, n = 0
    for y in 0..<size {
        for x in 0..<size where luma(px, size, x, y) > 110 {
            n += 1
            if luma(px, size, x, y) > 235 { hot += 1 }
        }
    }
    return n > 0 ? 100 * Double(hot) / Double(n) : 0
}

func box(_ px: [UInt8], _ from: Int, _ f: Int) -> [UInt8] {
    let to = from / f
    var o = [UInt8](repeating: 0, count: to * to * 4)
    for y in 0..<to {
        for x in 0..<to {
            for c in 0..<4 {
                var s = 0
                for dy in 0..<f { for dx in 0..<f { s += Int(px[((f*y+dy)*from + f*x+dx)*4 + c]) } }
                o[(y*to+x)*4+c] = UInt8(s / (f*f))
            }
        }
    }
    return o
}

var failures: [String] = []
func check(_ name: String, _ value: Double, _ limit: Double, over: Bool, _ note: String) {
    let bad = over ? value > limit : value < limit
    print(String(format: "  %-34s %7.2f  (%@ %.2f)  %@", (name as NSString).utf8String!,
                 value, over ? "limit" : "floor", limit, bad ? "FAIL" : "ok"))
    if bad { failures.append("\(name): \(String(format: "%.2f", value)) vs \(limit) — \(note)") }
}

print("winding — the streak pattern must not keep getting finer with uptime")
for st in styles {
    let young = fineness(render(st, phase: 2, size: S, bg: darkBG, cover: S), S)
    let old   = fineness(render(st, phase: 6300, size: S, bg: darkBG, cover: S), S)   // 1 h
    check("\(st.name): 1 h / launch", old / max(young, 0.01), 1.6, over: true,
          "the pattern is winding itself below the pixel grid; see DISK_REFRESH")
}

print("\nclipping — no style may jam itself into the top of the range")
for st in styles {
    check("\(st.name): % of disk above 235", clipped(render(st, phase: 2, size: S, bg: darkBG, cover: S), S),
          9.0, over: true, "check BLOOM_THRESHOLD against the disk's own brightness")
}

print("\naliasing — the lensed background against a 4x supersampled reference")
do {
    // BG_BLUR off on both sides. It softens the lensed background on purpose,
    // and it does so by *more* at 4x (the mip index moves with texel density),
    // so leaving it on would measure the deliberate blur rather than aliasing.
    let native = render(styles[0], phase: 2, size: S, bg: textBG, cover: S, bgBlur: 0)
    let reference = box(render(styles[0], phase: 2, size: S * 4, bg: textBG, cover: S, bgBlur: 0),
                        S * 4, 4)
    var sum = 0.0; var n = 0
    let c = Double(S) / 2, rad = Double(S) * 0.47
    for y in 0..<S {
        for x in 0..<S {
            let dx = Double(x) - c, dy = Double(y) - c
            guard dx*dx + dy*dy <= rad*rad else { continue }
            let d = luma(native, S, x, y) - luma(reference, S, x, y)
            sum += d * d; n += 1
        }
    }
    check("luma RMSE over a page of text", (sum / Double(max(n, 1))).squareRoot(), 9.0, over: true,
          "the background sampler has lost its mip filtering or its derivatives")
}

print("")
if failures.isEmpty {
    print("all clear")
} else {
    for f in failures { print("FAIL  " + f) }
    exit(1)
}
