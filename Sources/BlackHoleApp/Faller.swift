import AppKit
import Metal

/// GLSL's, since Swift has no equivalent.
private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

/// The thing currently being swallowed.
///
/// It lives here rather than as a layer over the render because the shader
/// paints it onto the sky plane, where the geodesics can bend it — which is the
/// whole difference between "an icon animating over a picture of a black hole"
/// and something actually falling into one. All this has to do is say where it
/// is; the lensing supplies the stretching, the arcs, the second image near the
/// photon ring and the disappearance.
@MainActor
final class Faller {
    static let shared = Faller()

    private(set) var texture: MTLTexture?
    private(set) var centre = SIMD2<Float>(0.5, 0.5)
    private(set) var size: Float = 0
    private(set) var alpha: Float = 0
    /// 0 while it is still holding together, rising as the tide wins.
    private(set) var tear: Float = 0
    /// Average colour of whatever is falling, so the disk can carry it briefly
    /// once the debris has joined.
    private(set) var colour = SIMD3<Float>(1, 1, 1)
    /// Set on the frame the stream reaches the disk, cleared once read.
    private(set) var delivered = false

    private var device: MTLDevice?
    private var start: CFTimeInterval = 0
    private var startRadius: Float = 0
    private var startAngle: Float = 0
    private var queue: [(NSImage, SIMD2<Float>)] = []

    /// Long enough to watch the disruption happen rather than infer it. Most of
    /// this is spent in the tidal region, coming apart, not on the approach.
    static let duration: CFTimeInterval = 4.6

    func configure(device: MTLDevice) {
        if self.device == nil { self.device = device }
    }

    /// `from` is in widget uv, y down, matching the shader.
    func swallow(_ image: NSImage, from: SIMD2<Float>) {
        // One at a time: a queue reads as a procession being eaten, where
        // several at once would just be clutter fighting for the same orbit.
        if alpha > 0.01 {
            queue.append((image, from))
            return
        }
        begin(image, from)
    }

    private func begin(_ image: NSImage, _ from: SIMD2<Float>) {
        guard let device, let tex = Self.upload(image, device: device) else { return }
        texture = tex
        colour = Self.averageColour(image)
        delivered = false
        let d = from - SIMD2<Float>(0.5, 0.5)
        // Dropped right on the middle there would be nothing to watch: it would
        // start inside the tidal radius and be shredded on the first frame.
        startRadius = max((d.x * d.x + d.y * d.y).squareRoot(), 0.34)
        startAngle = atan2(d.y, d.x)
        start = CACurrentMediaTime()
        centre = from
        size = 0.16
        alpha = 1
    }

    /// Advance one frame. Returns the moment it crosses the horizon, so the
    /// disk can flare on the way in rather than when it was dropped.
    @discardableResult
    func step(shadowRadius: Float) -> Bool {
        guard alpha > 0 else { return false }
        let u = Float(min((CACurrentMediaTime() - start) / Self.duration, 1))

        // A tidal disruption does not happen at the horizon — it happens at the
        // tidal radius, which is well outside it, and the debris is eaten
        // afterwards. Diving straight to the horizon put the shredding where
        // half the body was already behind the shadow and there was nothing to
        // watch. This settles at 1.15 r_h instead, so the stream comes apart in
        // full view and then goes out.
        let horizon = max(shadowRadius, 0.01)
        let settle = horizon * 1.15
        // Falls quickly to the tidal region, then crawls — which is where the
        // interesting part happens and where the time should go.
        let r = settle + (startRadius - settle) * pow(1 - u, 3.4)
        // A turn and a bit. Two and a half was a blur — the eye cannot follow
        // fragments it never sees twice in the same place.
        let phi = startAngle + 1.5 * 2 * .pi * (1 - pow(1 - u, 2.4))
        centre = SIMD2<Float>(0.5 + r * cos(phi), 0.5 + r * sin(phi))

        // Deliberately *not* faded here. The shader dims each fragment by its
        // own redshift, which is what makes the debris go out in the order it
        // reaches the horizon — doing it a second time on the object as a whole
        // double-dimmed it to 14% by the moment it began to come apart, and the
        // disruption happened where nobody could see it.
        // Holds full opacity through the disruption, then goes out over the
        // last of it — the shader is already reddening and dimming each
        // fragment by its own radius.
        alpha = u >= 1 ? 0 : (1 - smoothstep(0.88, 1.0, u))
        // Thinner as it stretches: the shear lengthens it, so keeping the
        // radial thickness would fatten the stream instead of drawing it out.
        size = 0.13 * (0.45 + 0.55 * (r / max(startRadius, 1e-4)))
        // Intact outside the tidal radius, fully shredded by the time it
        // settles. Ramped over that span rather than tied to 1/r³, which put
        // the whole transition into the last few frames.
        let t = smoothstep(horizon * 1.2, horizon * 2.2, r)
        tear = 1.1 * (1 - t)

        let crossed = u >= 0.82 && u - Float(1.0 / 60.0 / Self.duration) < 0.82
        if crossed { delivered = true }
        if u >= 1 {
            alpha = 0
            tear = 0
            texture = nil
            if !queue.isEmpty {
                let (image, from) = queue.removeFirst()
                begin(image, from)
            }
        }
        return crossed
    }

    func takeDelivery() -> Bool {
        defer { delivered = false }
        return delivered
    }

    /// Weighted by alpha, so a mostly-transparent icon reports the colour of
    /// the part you can actually see rather than drifting toward black.
    private static func averageColour(_ image: NSImage) -> SIMD3<Float> {
        let side = 16
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .one }
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        guard let out = ctx.makeImage(), let data = out.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return .one }
        var sum = SIMD3<Float>(0, 0, 0)
        var weight: Float = 0
        for i in stride(from: 0, to: side * side * 4, by: 4) {
            let a = Float(bytes[i + 3]) / 255
            guard a > 0.02 else { continue }
            // Premultiplied, so divide back out before averaging.
            sum += SIMD3<Float>(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2])) / 255 / a * a
            weight += a
        }
        guard weight > 0 else { return .one }
        let c = sum / weight
        // Push it toward the bright end: a muddy average injected into a disk
        // reads as dirt rather than as material.
        let peak = max(c.x, max(c.y, c.z))
        return peak > 0.05 ? c / peak : .one
    }

    private static func upload(_ image: NSImage, device: MTLDevice) -> MTLTexture? {
        let side = 128
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // Fit, not fill: a wide sprite squashed into a square would be
            // stretched twice, once here and once by the lensing.
            let s = min(CGFloat(side) / CGFloat(cg.width), CGFloat(side) / CGFloat(cg.height))
            let w = CGFloat(cg.width) * s, h = CGFloat(cg.height) * s
            ctx.draw(cg, in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2,
                                    width: w, height: h))
        }
        guard let out = ctx.makeImage(), let data = out.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                    withBytes: bytes, bytesPerRow: side * 4)
        return tex
    }
}
