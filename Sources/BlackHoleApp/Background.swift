import AppKit
import Metal

/// How the background texture maps into the widget: `uv * scale + off`.
struct BackgroundFit {
    var scaleX: Float = 1
    var scaleY: Float = 1
    var offX: Float = 0
    var offY: Float = 0

    /// Maps the widget's own rect into a full-display screen capture, so the
    /// shader samples exactly the pixels it is covering. The capture texture and
    /// the shader's uv both run top-down; `NSWindow.frame` does not, hence the
    /// y flip. Unused when the stream is cropped to the widget already.
    static func screenRect(window: NSRect, display: NSRect) -> BackgroundFit {
        guard display.width > 0, display.height > 0 else { return BackgroundFit() }
        return BackgroundFit(
            scaleX: Float(window.width / display.width),
            scaleY: Float(window.height / display.height),
            offX: Float((window.minX - display.minX) / display.width),
            offY: Float((display.maxY - window.maxY) / display.height))
    }
}

/// What the hole bends.
enum LensSource: String, CaseIterable, Identifiable {
    /// Live screen content behind the widget, via ScreenCaptureKit — your
    /// actual windows bend. Needs Screen Recording.
    case screen
    /// Nothing behind it: shadow, accretion disk and the procedural starfield
    /// only, with the rest of the widget transparent.
    case stars

    var id: String { rawValue }

    var label: String {
        switch self {
        case .screen: return "Live screen"
        case .stars:  return "Stars only"
        }
    }

    /// Whether the hole is covering real content. Drives the shader's
    /// `skyAlpha`.
    var isRealContent: Bool { self == .screen }
}

/// A 1×1 stand-in used until the first captured frame lands, and as the whole
/// background in "stars only".
enum PlaceholderTexture {
    static func make(device: MTLDevice) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        // A 1×1 texture always allocates; there is no sane fallback if the
        // device is gone anyway.
        let tex = device.makeTexture(descriptor: desc)!
        var px: [UInt8] = [16, 11, 10, 255]   // BGRA, near-black
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                    withBytes: &px, bytesPerRow: 4)
        return tex
    }
}
