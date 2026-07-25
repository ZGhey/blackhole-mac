import Foundation

/// Mirrors `struct Uniforms` in BlackHole.metal EXACTLY.
///
/// Every member is a `Float`, deliberately: an all-4-byte-scalar struct has the
/// same layout under Swift's and Metal's rules, so the two declarations cannot
/// silently drift apart the way a mixed `SIMD2`/`Float` struct would. Append in
/// groups of four and shrink the pads; never reorder.
///
/// The shader's copy is source text and can never be shared, so the two are held
/// together by the `contract` section of `check-render`, which reads this
/// struct's field order back out with `Mirror` and compares it against the
/// struct parsed out of BlackHole.metal. That catches a reorder, which a size
/// check cannot.
///
/// Every member is `internal(set)`: read-only outside this module, so
/// `FrameUniforms.make` is the only thing that fills one in. Half-filling a
/// Uniforms at the call site is what put 37 fields in Params and the other 11
/// in Renderer.
public struct Uniforms {
    public internal(set) var time: Float = 0
    public internal(set) var resX: Float = 1
    public internal(set) var resY: Float = 1
    /// How far the lensed background reaches beyond the ring, as a multiple of
    /// it. The composition always fills the widget, so this is the only thing
    /// that decides the proportions — the ring's size on screen comes from the
    /// window.
    public internal(set) var halo: Float = 1.25

    public internal(set) var lensDepth: Float = 0
    public internal(set) var lensFalloff: Float = 0
    public internal(set) var starGain: Float = 0
    /// The disk's rotation, integrated on the CPU. Passing a *speed* the shader
    /// multiplies by time would jump every streak the instant the rate changed
    /// — and the rate now changes constantly, with flares and audio.
    public internal(set) var diskPhase: Float = 0

    public internal(set) var diskInner: Float = 0
    public internal(set) var diskOuter: Float = 0
    public internal(set) var diskIncl: Float = 0
    public internal(set) var diskRoll: Float = 0

    public internal(set) var diskGain: Float = 0
    public internal(set) var diskOpacity: Float = 0
    public internal(set) var diskTemp: Float = 0
    public internal(set) var dopplerMix: Float = 0

    public internal(set) var diskBeam: Float = 0
    public internal(set) var diskSpeed: Float = 0
    public internal(set) var diskWind: Float = 0
    public internal(set) var diskContrast: Float = 0

    public internal(set) var exposure: Float = 0
    /// 0…1 transient: a mass just crossed the horizon, so the disk brightens
    /// and heats the way infalling matter really does.
    public internal(set) var flare: Float = 0
    public internal(set) var nSteps: Float = 48
    public internal(set) var bgDim: Float = 1

    /// Maps the widget's rect into the background texture: `uv * scale + off`.
    public internal(set) var bgScaleX: Float = 1
    public internal(set) var bgScaleY: Float = 1
    public internal(set) var bgOffX: Float = 0
    public internal(set) var bgOffY: Float = 0

    /// 1 = the background texture is real content the hole should cover (the
    /// screen capture); 0 = nothing behind it, so only the shadow and the
    /// disk's own light are drawn and the rest of the widget shows through.
    public internal(set) var skyAlpha: Float = 1
    /// 0…1 system-audio envelope, when the disk is set to pulse with it.
    public internal(set) var audio: Float = 0
    /// Brightness of the orbiting hot spot (0 = off) and the radius it orbits
    /// at, in Schwarzschild radii. Closer in orbits faster — Keplerian, then
    /// slowed again by the gravitational time dilation at that radius.
    public internal(set) var spotGain: Float = 0
    public internal(set) var spotRadius: Float = 0

    /// Where the hole sits relative to the centre of the widget, as a fraction
    /// of its height. The lensed background is a static mapping of whatever is
    /// behind the widget, so the halo only moves when the warp field does.
    public internal(set) var driftX: Float = 0
    public internal(set) var driftY: Float = 0
    /// Multiplier on the lensing depth. Swallowing mass makes a hole heavier,
    /// so the warp deepens for a moment after it eats.
    public internal(set) var lensBoost: Float = 1
    /// Extra brightness for higher-order disk images — the photon ring.
    public internal(set) var ringGain: Float = 0

    /// Whatever is being swallowed: its offset from the hole's centre in
    /// aspect-corrected screen units, how wide it is, and how much is left.
    /// Drawn in front of the hole — light from something falling in on the
    /// viewer's side reaches the eye directly, so what happens to it is tidal
    /// rather than optical.
    public internal(set) var fallX: Float = 0
    public internal(set) var fallY: Float = 0
    public internal(set) var fallSize: Float = 0
    public internal(set) var fallAlpha: Float = 0

    /// How close the pointer is, 0…1. The disk brightens a little and the hole
    /// leans toward it — the attraction runs from the hole to the pointer, not
    /// the other way, because nothing here is allowed to move the cursor.
    public internal(set) var hover: Float = 0
    /// How far the tide has sheared whatever is falling in. Drives the
    /// Keplerian lead that draws it into a stream and the seams it comes apart
    /// along.
    public internal(set) var fallTear: Float = 0

    /// Where round the disk the debris was delivered, how strongly it is still
    /// glowing, and what colour it used to be. The swallowed thing does not
    /// vanish — it circularises and becomes disk, which is why a real tidal
    /// disruption is a flare that lasts rather than an event that ends.
    public internal(set) var feedAngle: Float = 0
    public internal(set) var feedStrength: Float = 0
    public internal(set) var feedR: Float = 1
    public internal(set) var feedG: Float = 1
    public internal(set) var feedB: Float = 1
    /// How brightly the plunging region inside the ISCO still radiates. 0 is
    /// the old hard cut at DISK_INNER.
    public internal(set) var plunge: Float = 0.5

    /// Extra blur for the lensed background, in proportion to how hard the lens
    /// is compressing it. 0 is the physically honest sample.
    public internal(set) var bgBlur: Float = 1.5
    /// How many seconds of Keplerian shear the streak field is allowed to
    /// accumulate before it is replaced by a fresh copy. Without a bound the
    /// pattern winds itself below the pixel grid and the disk goes to noise.
    public internal(set) var diskRefresh: Float = 26
    public internal(set) var pad1: Float = 0
    public internal(set) var pad2: Float = 0

    /// Only `FrameUniforms.make` has anything to say about the contents.
    internal init() {}

    /// Field names in declaration order — which, for an all-`Float` struct, is
    /// the memory layout. `check-render` compares this against the struct it
    /// parses out of BlackHole.metal.
    public static var fieldNames: [String] {
        Mirror(reflecting: Uniforms()).children.compactMap(\.label)
    }
}
