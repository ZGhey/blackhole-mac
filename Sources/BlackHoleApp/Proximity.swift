import AppKit
import Metal

/// The pointer, being swallowed.
///
/// Two earlier attempts at this were wrong in different ways. Pulling the real
/// cursor toward the hole made the widget genuinely tiresome to leave — anything
/// that can hold the pointer is a bug wearing a costume. Making the *hole* react
/// instead was safe but beside the point: that is the widget and the mouse
/// interacting, when what should happen is that the mouse falls in.
///
/// So the pointer is never touched. A copy of it is painted onto the sky plane —
/// the same slot a dropped file uses — where the tracer stretches it, reddens it
/// and finally swallows it. The deeper the real pointer goes, the further behind
/// its image is dragged; move back out and the image catches up, at no cost. The
/// system cursor is hidden while its image is on screen, so there is one
/// pointer, not two.
@MainActor
final class Proximity {
    static let shared = Proximity()

    private var monitor: Any?
    private var enabled = false
    private var device: MTLDevice?
    private var sprite: MTLTexture?
    private var cursorHidden = false

    /// Set by PanelController: where the widget is and how big.
    var centre: CGPoint = .zero
    var radius: CGFloat = 0

    /// 0 outside, rising to 1 at the middle. Smoothed, so crossing the rim is a
    /// swell rather than a switch.
    private(set) var hover: Float = 0
    /// Where the pointer's image is, in widget uv (y down), how wide, and how
    /// much of it is left.
    private(set) var ghost = SIMD2<Float>(0.5, 0.5)
    private(set) var ghostAlpha: Float = 0
    private(set) var ghostSize: Float = 0
    private(set) var ghostTear: Float = 0

    func configure(device: MTLDevice) {
        guard self.device == nil else { return }
        self.device = device
        sprite = Self.cursorSprite(device: device)
    }

    var ghostTexture: MTLTexture? { ghostAlpha > 0.01 ? sprite : nil }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            // Mouse events need no permission; only key events do.
            monitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            ) { [weak self] _ in
                Task { @MainActor in self?.sample() }
            }
            sample()
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            hover = 0
            ghostAlpha = 0
            showCursor()
        }
    }

    /// Driven from the render loop too, so the image keeps falling and the
    /// cursor is restored even when the pointer has stopped moving.
    func step(shadowRadius: Float) {
        guard enabled else { return }
        sample(shadowRadius: shadowRadius)
    }

    private func sample(shadowRadius: Float = 0.1) {
        guard radius > 1 else { hover = 0; ghostAlpha = 0; showCursor(); return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - centre.x, dy = mouse.y - centre.y
        let r = (dx * dx + dy * dy).squareRoot()

        // Reaches a little past the disc, so the disk starts to brighten before
        // the pointer is on top of it.
        let target = Float(max(0, 1 - r / (radius * 1.45)))
        hover += (target * target - hover) * 0.18

        guard r < radius else {
            ghostAlpha = 0
            ghostTear = 0
            showCursor()
            return
        }

        // Widget uv, y down.
        let side = radius * 2
        let u = SIMD2<Float>(Float(0.5 + dx / side), Float(0.5 - dy / side))
        let d = u - SIMD2<Float>(0.5, 0.5)
        let ru = max((d.x * d.x + d.y * d.y).squareRoot(), 1e-4)

        // Dragged inward, harder the deeper it is, and never quite to the
        // horizon — nothing reaches it.
        let depth = Float(1 - r / radius)
        let horizon = max(shadowRadius, 0.01)
        let pulled = max(ru * (1 - 0.75 * depth * depth), horizon * 1.02)
        ghost = SIMD2<Float>(0.5, 0.5) + d / ru * pulled

        // Not faded here: the shader dims each fragment by its own redshift, and
        // doing it twice hides the whole effect.
        ghostAlpha = 1
        ghostSize = 0.085 * (0.45 + 0.55 * min(pulled / 0.35, 1))
        ghostTear = min(pow(horizon / max(pulled, horizon), 3) * 0.8, 1.0)
        if ghostAlpha > 0.02 { hideCursor() } else { showCursor() }
    }

    // Hiding is per-process and the system restores it if we die, so a crash
    // cannot leave the machine without a pointer. Balanced through a flag
    // rather than by trusting calls to pair up.
    private func hideCursor() {
        guard !cursorHidden else { return }
        cursorHidden = true
        CGDisplayHideCursor(CGMainDisplayID())
    }

    private func showCursor() {
        guard cursorHidden else { return }
        cursorHidden = false
        CGDisplayShowCursor(CGMainDisplayID())
    }

    private static func cursorSprite(device: MTLDevice) -> MTLTexture? {
        let image = NSCursor.arrow.image
        let side = 96
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
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
