import Foundation

/// Mirrors `struct Uniforms` in BlackHole.metal EXACTLY.
///
/// Every member is a `Float`, deliberately: an all-4-byte-scalar struct has the
/// same layout under Swift's and Metal's rules, so the two declarations cannot
/// silently drift apart the way a mixed `SIMD2`/`Float` struct would. Append in
/// groups of four and shrink the pads; never reorder.
struct Uniforms {
    var time: Float = 0
    var resX: Float = 1
    var resY: Float = 1
    /// How far the lensed background reaches beyond the ring, as a multiple of
    /// it. The composition always fills the widget, so this is the only thing
    /// that decides the proportions — the ring's size on screen comes from the
    /// window.
    var halo: Float = 1.25

    var lensDepth: Float = 0
    var lensFalloff: Float = 0
    var starGain: Float = 0
    /// The disk's rotation, integrated on the CPU. Passing a *speed* the shader
    /// multiplies by time would jump every streak the instant the rate changed
    /// — and the rate now changes constantly, with flares and audio.
    var diskPhase: Float = 0

    var diskInner: Float = 0
    var diskOuter: Float = 0
    var diskIncl: Float = 0
    var diskRoll: Float = 0

    var diskGain: Float = 0
    var diskOpacity: Float = 0
    var diskTemp: Float = 0
    var dopplerMix: Float = 0

    var diskBeam: Float = 0
    var diskSpeed: Float = 0
    var diskWind: Float = 0
    var diskContrast: Float = 0

    var exposure: Float = 0
    /// 0…1 transient: a mass just crossed the horizon, so the disk brightens
    /// and heats the way infalling matter really does.
    var flare: Float = 0
    var nSteps: Float = 48
    var bgDim: Float = 1

    /// Maps the widget's rect into the background texture: `uv * scale + off`.
    var bgScaleX: Float = 1
    var bgScaleY: Float = 1
    var bgOffX: Float = 0
    var bgOffY: Float = 0

    /// 1 = the background texture is real content the hole should cover (the
    /// screen capture); 0 = nothing behind it, so only the shadow and the
    /// disk's own light are drawn and the rest of the widget shows through.
    var skyAlpha: Float = 1
    /// 0…1 system-audio envelope, when the disk is set to pulse with it.
    var audio: Float = 0
    /// Brightness of the orbiting hot spot (0 = off) and the radius it orbits
    /// at, in Schwarzschild radii. Closer in orbits faster — Keplerian, then
    /// slowed again by the gravitational time dilation at that radius.
    var spotGain: Float = 0
    var spotRadius: Float = 0

    /// Where the hole sits relative to the centre of the widget, as a fraction
    /// of its height. The lensed background is a static mapping of whatever is
    /// behind the widget, so the halo only moves when the warp field does.
    var driftX: Float = 0
    var driftY: Float = 0
    /// Multiplier on the lensing depth. Swallowing mass makes a hole heavier,
    /// so the warp deepens for a moment after it eats.
    var lensBoost: Float = 1
    /// Extra brightness for higher-order disk images — the photon ring.
    var ringGain: Float = 0

    /// Whatever is being swallowed: its offset from the hole's centre in
    /// aspect-corrected screen units, how wide it is, and how much is left.
    /// Drawn in front of the hole — light from something falling in on the
    /// viewer's side reaches the eye directly, so what happens to it is tidal
    /// rather than optical.
    var fallX: Float = 0
    var fallY: Float = 0
    var fallSize: Float = 0
    var fallAlpha: Float = 0

    /// How close the pointer is, 0…1. The disk brightens a little and the hole
    /// leans toward it — the attraction runs from the hole to the pointer, not
    /// the other way, because nothing here is allowed to move the cursor.
    var hover: Float = 0
    /// How far the tide has sheared whatever is falling in. Drives the
    /// Keplerian lead that draws it into a stream and the seams it comes apart
    /// along.
    var fallTear: Float = 0

    /// Where round the disk the debris was delivered, how strongly it is still
    /// glowing, and what colour it used to be. The swallowed thing does not
    /// vanish — it circularises and becomes disk, which is why a real tidal
    /// disruption is a flare that lasts rather than an event that ends.
    var feedAngle: Float = 0
    var feedStrength: Float = 0
    var feedR: Float = 1
    var feedG: Float = 1
    var feedB: Float = 1
    /// How brightly the plunging region inside the ISCO still radiates. 0 is
    /// the old hard cut at DISK_INNER.
    var plunge: Float = 0.5

    /// Extra blur for the lensed background, in proportion to how hard the lens
    /// is compressing it. 0 is the physically honest sample.
    var bgBlur: Float = 1.5
    /// How many seconds of Keplerian shear the streak field is allowed to
    /// accumulate before it is replaced by a fresh copy. Without a bound the
    /// pattern winds itself below the pixel grid and the disk goes to noise.
    var diskRefresh: Float = 26
    var pad1: Float = 0
    var pad2: Float = 0
}
