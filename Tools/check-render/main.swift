// Four checks, each of which corresponds to a bug that shipped.
//
//   swift run check-render Sources/BlackHoleApp/BlackHole.metal
//
// There is nothing to unit-test in a fragment shader, but there is plenty to
// measure. These are the checks that would have caught the worst things this
// renderer has done, kept because each one was found the hard way:
//
//   contract   The Uniforms struct is all-float so that declaration order is
//              the memory layout — which means a reorder on one side feeds
//              every field after it to the wrong parameter, silently, and no
//              size check notices. Swift's declaration is read back with
//              Mirror and compared, in order, against the struct parsed out of
//              the shader.
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
// The styles come from Specs.styles, so a style added to the app is measured
// here without anyone having to remember it.
//
// Prints numbers and exits non-zero if any of them has drifted. The thresholds
// are set well clear of the values as they stand, not at them — this is a trip
// wire, not a golden image.
import AppKit
import BlackHoleCore
import Metal

let shaderPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Sources/BlackHoleApp/BlackHole.metal"
let S = 600, TW = 1024

let shaderSource = try String(contentsOfFile: shaderPath, encoding: .utf8)
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let library = try device.makeLibrary(source: shaderSource, options: nil)
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

/// Through the same assembler the app uses. This was fifty-two floats in a
/// literal array, in declaration order, typed out by hand.
func render(_ t: Tunables, phase: Float, size: Int, bg: MTLTexture, cover: Int) -> [UInt8] {
    let fit = BackgroundFit(scaleX: Float(cover) / Float(TW), scaleY: Float(cover) / Float(TW),
                            offX: 0.1, offY: 0.1)
    var u = FrameUniforms.make(t, .offscreen(t, size: size, phase: phase, bgFit: fit))

    let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                      width: size, height: size, mipmapped: false)
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

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

print("contract — the two Uniforms declarations must agree, field for field")
do {
    let counts = UniformContract.fieldCounts(metalSource: shaderSource)
    let sameCount = counts.swift == counts.metal && counts.metal > 0
    print("  \(pad("field count", 34)) \(pad("\(counts.swift) vs \(counts.metal)", 9))  \(sameCount ? "ok" : "FAIL")")
    if !sameCount {
        failures.append("field count: Uniforms.swift has \(counts.swift), BlackHole.metal has \(counts.metal)")
    }
    let mismatches = UniformContract.check(metalSource: shaderSource)
    print("  \(pad("order + names", 34)) \(pad(mismatches.isEmpty ? "identical" : "differ", 9))  \(mismatches.isEmpty ? "ok" : "FAIL")")
    for m in mismatches.prefix(8) { print("      \(m.describe)") }
    if !mismatches.isEmpty {
        failures.append("order + names: \(mismatches.count) position(s) disagree — the struct must never be reordered")
    }
}

print("\nwinding — the streak pattern must not keep getting finer with uptime")
for (name, patch) in Specs.styles {
    let t = Tunables().applying(patch)
    let young = fineness(render(t, phase: 2, size: S, bg: darkBG, cover: S), S)
    let old   = fineness(render(t, phase: 6300, size: S, bg: darkBG, cover: S), S)   // 1 h
    check("\(name): 1 h / launch", old / max(young, 0.01), 1.6, over: true,
          "the pattern is winding itself below the pixel grid; see DISK_REFRESH")
}

print("\nclipping — no style may jam itself into the top of the range")
for (name, patch) in Specs.styles {
    let t = Tunables().applying(patch)
    check("\(name): % of disk above 235",
          clipped(render(t, phase: 2, size: S, bg: darkBG, cover: S), S),
          9.0, over: true, "check BLOOM_THRESHOLD against the disk's own brightness")
}

print("\naliasing — the lensed background against a 4x supersampled reference")
do {
    // BG_BLUR off on both sides. It softens the lensed background on purpose,
    // and it does so by *more* at 4x (the mip index moves with texel density),
    // so leaving it on would measure the deliberate blur rather than aliasing.
    var t = Tunables().applying(Specs.styles[0].1)
    t["BG_BLUR"] = 0
    let native = render(t, phase: 2, size: S, bg: textBG, cover: S)
    let reference = box(render(t, phase: 2, size: S * 4, bg: textBG, cover: S), S * 4, 4)
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

print("\ncycle — the style rotation is a pure function of the clock")
do {
    func want(_ name: String, _ got: String, _ expected: String, _ note: String) {
        let ok = got == expected
        print("  \(pad(name, 34)) \(pad(got, 9))  \(ok ? "ok" : "FAIL (want \(expected))")")
        if !ok { failures.append("\(name): \(got) vs \(expected) — \(note)") }
    }
    // The two walks below take their expected value from their own first
    // element, so what they assert is the *stepping* — one style per interval,
    // wrapping at the end — and not which style the rotation happens to start
    // on. That is deliberate: where it starts is the epoch's business, and
    // pinning it here would make the check a golden value nobody could read.
    var cal = Calendar(identifier: .gregorian)
    // A zone that observes DST, and one whose local midnight is nowhere near
    // UTC midnight: between them, an implementation that quietly used UTC for
    // the daily interval, or the calendar for the hourly one, shows up.
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    let hour: TimeInterval = 3600

    // Hourly advances exactly one slot an hour and wraps at the end.
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let walk = (0..<5).map { StyleCycle.index(at: t0.addingTimeInterval(Double($0) * hour),
                                              interval: .hourly, count: 3, calendar: cal)! }
    want("hourly: 5 h over 3 styles", walk.map(String.init).joined(),
         (0..<5).map { String((walk[0] + $0) % 3) }.joined(),
         "the rotation must step one style an hour and wrap")

    // Eight hours asleep lands on the style of the hour, not eight steps on
    // from wherever it was — this is what makes the cycle need no stored state.
    want("hourly: 8 h gap == 8 steps",
         String(StyleCycle.index(at: t0.addingTimeInterval(8 * hour),
                                 interval: .hourly, count: 5, calendar: cal)!),
         String((StyleCycle.index(at: t0, interval: .hourly, count: 5, calendar: cal)! + 8) % 5),
         "the index must be computed from the clock, never accumulated")

    // Daylight saving. 2025-03-09 is a 23-hour day in New York, and that is the
    // only thing about the daily interval that can actually go wrong: the index
    // sequence comes out the same either way, so what discriminates a correct
    // implementation is *when* it switches. Adding 86400 seconds to the last
    // midnight would put this one switch at 01:00 and leave every switch after
    // it an hour out.
    let dstMidnight = Date(timeIntervalSince1970: 1_741_496_400)   // 2025-03-09 00:00 EST
    let dstNext = StyleCycle.nextBoundary(after: dstMidnight.addingTimeInterval(hour),
                                          interval: .daily, calendar: cal)!
    want("daily: the 23-hour day is 23 h",
         String(format: "%.1f", dstNext.timeIntervalSince(dstMidnight) / hour), "23.0",
         "daily must land on the next local midnight, not 86400 seconds on")

    // Consecutive local midnights are consecutive styles, wrapping at the end.
    let midnights = (0..<4).map { cal.date(byAdding: .day, value: $0, to: dstMidnight)! }
    let dstWalk = midnights.map { StyleCycle.index(at: $0, interval: .daily,
                                                   count: 3, calendar: cal)! }
    want("daily: 4 days over 3 styles", dstWalk.map(String.init).joined(),
         (0..<4).map { String((dstWalk[0] + $0) % 3) }.joined(),
         "the rotation must step one style a day and wrap")

    // Dates before 1970 make the slot negative, and Swift's % keeps the sign.
    let ancient = Date(timeIntervalSince1970: -5 * hour)
    let old = StyleCycle.index(at: ancient, interval: .hourly, count: 3, calendar: cal)!
    want("hourly: index before 1970 in range", String(old >= 0 && old < 3), "true",
         "a negative remainder would index out of the rotation")

    // A boundary lands strictly in the future, or the timer refires forever.
    let onBoundary = Date(timeIntervalSince1970: 1_700_000_000 - 1_700_000_000.truncatingRemainder(dividingBy: 3600))
    let next = StyleCycle.nextBoundary(after: onBoundary, interval: .hourly, calendar: cal)!
    want("hourly: boundary is in the future", String(next > onBoundary), "true",
         "a boundary equal to now spins the switch timer")
    want("hourly: boundary lands on the hour",
         String(next.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600) == 0), "true",
         "hourly must switch on the hour, not on whenever the app launched")
    want("daily: boundary is a local midnight",
         String(cal.startOfDay(for: dstNext) == dstNext && dstNext > dstMidnight), "true",
         "daily must switch at local midnight, not at UTC midnight")

    // Nothing selected is not a crash, it is nothing to rotate.
    want("empty rotation yields no index",
         String(StyleCycle.index(at: t0, interval: .hourly, count: 0, calendar: cal) == nil), "true",
         "an empty selection must not divide by zero")
    want("off yields no index",
         String(StyleCycle.index(at: t0, interval: .off, count: 3, calendar: cal) == nil), "true",
         "off must not pick a style")
}

print("")
if failures.isEmpty {
    print("all clear")
} else {
    for f in failures { print("FAIL  " + f) }
    exit(1)
}
