import AppKit
import Metal

/// What the hole bends.
enum LensSource: String, CaseIterable, Identifiable {
    /// Live screen content behind the widget, via ScreenCaptureKit — your
    /// actual windows bend. Needs Screen Recording.
    case screen
    /// Nothing behind it: shadow, accretion disk and the procedural starfield
    /// only, with the rest of the widget transparent.
    ///
    /// The case is still called `stars` because the stored value is, but the
    /// label is not: this is the state the widget launches in before anybody has
    /// granted Screen Recording, and what it actually shows there is the disk
    /// over a transparent background — seven of the eight built-in styles set
    /// `STAR_GAIN` to 0, so promising stars would be a lie. What the user is
    /// choosing between is whether the screen gets recorded at all.
    case stars

    var id: String { rawValue }

    var label: String {
        switch self {
        case .screen: return "Live screen"
        case .stars:  return "No screen recording"
        }
    }
}

/// A 1×1 stand-in used until the first captured frame lands, and as the whole
/// background when the screen is not being recorded.
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
