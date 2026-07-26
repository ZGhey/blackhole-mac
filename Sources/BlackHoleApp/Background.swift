import AppKit
import Metal

/// What the hole bends.
enum LensSource: String, CaseIterable, Identifiable {
    /// Live screen content behind the widget, via ScreenCaptureKit — your
    /// actual windows bend. Needs Screen Recording.
    case screen
    /// Nothing captured: shadow, accretion disk and the procedural starfield
    /// only, with the rest of the widget transparent.
    ///
    /// The case is still called `stars` because the stored value is, and the
    /// label is neither that nor "no background", because both would describe
    /// the wrong thing. `Renderer` passes `skyAlpha: 0` here, so everywhere the
    /// warp would have been the widget's alpha is 0 and **the real screen shows
    /// through, undistorted** — measured on the alpha channel: 0 across the
    /// halo, 255 in the shadow, which `captured` keeps opaque so a hole reads as
    /// a hole rather than as a gap. What is actually being chosen is whether the
    /// screen gets bent, and the price of bending it is that it has to be
    /// recorded first.
    ///
    /// It is not "stars" either: seven of the eight built-in styles set
    /// `STAR_GAIN` to 0.
    case stars

    var id: String { rawValue }

    /// Localized, unlike most enum labels here — this one is in the menu bar
    /// now, not in the untranslated Advanced panel it started in.
    var label: String {
        switch self {
        case .screen: return L("menu.lens.bend")
        case .stars:  return L("menu.lens.plain")
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
