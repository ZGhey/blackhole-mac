import Foundation
import SwiftUI

/// Display metadata for one tunable, for the Advanced sheet. Ported from the
/// Ghostty tuner's ParamSpec.swift — same names, so its presets paste straight in.
struct ParamSpec {
    let range: ClosedRange<Double>
    let group: String
    let help: String
    let def: Double

    init(_ range: ClosedRange<Double>, _ group: String, _ def: Double, _ help: String) {
        self.range = range
        self.group = group
        self.def = def
        self.help = help
    }
}

enum Specs {
    static let groupOrder = ["Black hole", "Accretion disk", "Color & light", "Render"]

    /// Order within each group, since a dictionary has none.
    static let order: [String] = [
        "HOLE_FILL", "LENS_DEPTH", "LENS_FALLOFF", "STAR_GAIN", "DRIFT", "DRIFT_SPEED",
        "DISK_INNER", "DISK_OUTER", "DISK_INCL", "DISK_ROLL",
        "DISK_GAIN", "DISK_OPACITY", "DISK_SPEED", "DISK_WIND", "DISK_CONTRAST",
        "SPOT_GAIN", "SPOT_RADIUS",
        "DISK_TEMP", "DOPPLER_MIX", "DISK_BEAM", "EXPOSURE", "RING_GAIN",
        "DISK_RATE",
        "BLOOM", "BLOOM_THRESHOLD", "N_STEPS", "BG_DIM",
    ]

    static let all: [String: ParamSpec] = [
        "HOLE_FILL":     ParamSpec(0.02...0.20, "Black hole", 0.10, "Shadow radius as a fraction of the widget. The widget is the frame, so resizing the window resizes the hole with it — this only changes how much of the frame it takes up"),
        "LENS_DEPTH":    ParamSpec(0.0...20.0, "Black hole", 13.0, "Distance from the hole to the screen behind it, in Schwarzschild radii — bigger bends what's behind harder"),
        "LENS_FALLOFF":  ParamSpec(2.0...40.0, "Black hole", 7.0, "How far the lensing reaches, in shadow radii. Real bending falls off as 1/b and never stops; this fades it out. Beyond the widget's silhouette it is tapered away regardless"),
        "DRIFT":         ParamSpec(0.0...0.12, "Black hole", 0.035, "How far the hole wanders inside the widget, as a fraction of its height. The lensed halo is a static mapping of whatever is behind — it only moves when the warp field itself does, so this is what keeps the outer rings alive"),
        "DRIFT_SPEED":   ParamSpec(0.0...3.0, "Black hole", 1.0, "How fast it wanders. The path is two incommensurate sines per axis, so it never repeats"),
        "STAR_GAIN":     ParamSpec(0.0...2.0, "Black hole", 0.0, "Brightness of the lensed starfield (0 = off). Worth raising with the “Stars only” lens, where there is nothing else to bend"),

        "DISK_INNER":    ParamSpec(1.6...8.0, "Accretion disk", 1.8, "Inner edge in Schwarzschild radii; 3 is the ISCO (innermost stable circular orbit)"),
        "DISK_OUTER":    ParamSpec(4.0...20.0, "Accretion disk", 8.0, "Outer edge in Schwarzschild radii. The hole is scaled down automatically if this would push the disk past the widget's edge"),
        "DISK_INCL":     ParamSpec(0.0...1.5707, "Accretion disk", 1.5, "Inclination in radians: 0 = face-on, π/2 = edge-on (the Interstellar look)"),
        "DISK_ROLL":     ParamSpec(-3.1416...3.1416, "Accretion disk", 0.35, "Rotation of the whole system in the screen plane, radians"),
        "DISK_GAIN":     ParamSpec(0.0...4.0, "Accretion disk", 2.2, "Disk emission brightness"),
        "DISK_OPACITY":  ParamSpec(0.0...1.0, "Accretion disk", 0.9, "How much the near disk hides the shadow, the far-side images and the screen behind it"),
        "DISK_SPEED":    ParamSpec(-10.0...10.0, "Accretion disk", 5.0, "Streak pattern speed; negative reverses the orbital direction"),
        "DISK_WIND":     ParamSpec(0.0...15.0, "Accretion disk", 7.0, "Spiral winding tightness of the streaks"),
        "DISK_CONTRAST": ParamSpec(0.0...2.0, "Accretion disk", 1.6, "Streak contrast: 0 = smooth haze, higher = sharp filaments"),
        "SPOT_GAIN":     ParamSpec(0.0...4.0, "Accretion disk", 1.8, "Brightness of an orbiting hot spot — a compact overdensity on a near-ISCO orbit, the same picture used to model Sgr A*'s infrared flares. 0 turns it off. It is what gives the ring a feature you can actually watch go round"),
        "SPOT_RADIUS":   ParamSpec(1.8...8.0, "Accretion disk", 2.4, "Which orbit the hot spot rides, in Schwarzschild radii. Closer in is faster and more strongly beamed, and lenses harder over the shadow"),

        "DISK_TEMP":     ParamSpec(2000.0...20000.0, "Color & light", 5500.0, "Blackbody temperature of the hottest annulus, Kelvin"),
        "DOPPLER_MIX":   ParamSpec(0.0...1.0, "Color & light", 0.6, "Relativistic Doppler shift + beaming asymmetry: 0 = off, 1 = full physics"),
        "DISK_BEAM":     ParamSpec(0.0...6.0, "Color & light", 2.5, "Beaming exponent: observed intensity scales as g^N (3 ≈ photon-count, 4 ≈ bolometric)"),
        "RING_GAIN":     ParamSpec(0.0...4.0, "Color & light", 1.2, "Extra brightness for the photon ring — the stack of higher-order images made by rays that wound around the photon sphere. It is the sharpest structure in the picture and the faintest, so the disk's own glow buries it without this"),
        "EXPOSURE":      ParamSpec(0.05...5.0, "Color & light", 1.4, "Tonemap exposure for the disk light; the screen behind is never tonemapped"),

        "DISK_RATE":     ParamSpec(0.0...1.0, "Render", 0.35, "How fast the disk turns overall — the gravitational time dilation theme. Lower reads as heavier"),
        "BLOOM":         ParamSpec(0.0...2.0, "Render", 0.55, "How much bright light spills into its surroundings. 0 skips the four extra passes entirely — it is what makes the disk read as bright rather than merely pale"),
        "BLOOM_THRESHOLD": ParamSpec(0.2...1.0, "Render", 0.55, "How bright a pixel must be before it starts to glow"),
        "N_STEPS":       ParamSpec(8...128, "Render", 48, "Geodesic integration steps per pixel — the main GPU dial. Only pixels near the hole pay it"),
        "BG_DIM":        ParamSpec(0.0...1.0, "Render", 1.0, "Dims the lensed screen so the disk reads brighter against busy content"),
    ]

    static func spec(_ name: String) -> ParamSpec {
        all[name] ?? ParamSpec(0...1, "Render", 0, "")
    }

    static var defaults: [String: Double] { all.mapValues(\.def) }

    static func grouped() -> [(String, [String])] {
        groupOrder.compactMap { group in
            let members = order.filter { spec($0).group == group }
            return members.isEmpty ? nil : (group, members)
        }
    }

    /// The black hole's look. Each style names only the parameters it cares
    /// about; the rest keep their current values. `DISK_OUTER` varies a lot
    /// between them (7 r_s for Gargantua, 16 for Blazar) — the shader scales
    /// the hole down to keep the disk inside the widget, so every style fits
    /// the same frame without being clipped.
    static let styles: [(String, [String: Double])] = [
        // dense molten edge-on disk, thick filaments, everything overdriven
        ("Inferno", [
            "DISK_TEMP": 5500, "DISK_INCL": 1.50, "DISK_ROLL": 0.35,
            "DISK_INNER": 1.8, "DISK_OUTER": 8.0, "DISK_OPACITY": 0.90,
            "DOPPLER_MIX": 0.6, "DISK_BEAM": 2.5, "DISK_GAIN": 2.2,
            "DISK_CONTRAST": 1.6, "DISK_WIND": 7.0, "DISK_SPEED": 5.0,
            "STAR_GAIN": 0.0, "EXPOSURE": 1.4,
        ]),
        ("Gargantua", [
            "DISK_TEMP": 4500, "DISK_INCL": 1.52, "DISK_ROLL": 0.10,
            "DISK_INNER": 2.2, "DISK_OUTER": 7.0, "DISK_OPACITY": 0.85,
            "DOPPLER_MIX": 0.35, "DISK_BEAM": 2.0, "DISK_GAIN": 1.4,
            "DISK_CONTRAST": 0.5, "DISK_WIND": 7.0, "DISK_SPEED": 5.0,
            "STAR_GAIN": 0.0, "EXPOSURE": 1.2,
        ]),
        // the EHT image of M87*: warm orange donut, nearly face-on, one beamed
        // bright side, smooth haze instead of filaments
        ("M87* donut", [
            "DISK_TEMP": 3800, "DISK_INCL": 0.55, "DISK_ROLL": -0.30,
            "DISK_INNER": 2.2, "DISK_OUTER": 6.0, "DISK_OPACITY": 0.45,
            "DOPPLER_MIX": 0.9, "DISK_BEAM": 3.5, "DISK_GAIN": 1.6,
            "DISK_CONTRAST": 0.4, "DISK_WIND": 3.0, "DISK_SPEED": 2.5,
            "STAR_GAIN": 0.0, "EXPOSURE": 1.1,
        ]),
        ("Face-on ember", [
            "DISK_TEMP": 6500, "DISK_INCL": 0.30, "DISK_ROLL": 0.0,
            "DISK_INNER": 3.0, "DISK_OUTER": 10.0, "DISK_OPACITY": 0.5,
            "DOPPLER_MIX": 0.8, "DISK_BEAM": 2.5, "DISK_GAIN": 1.0,
            "DISK_CONTRAST": 1.1, "DISK_WIND": 7.0, "DISK_SPEED": 5.0,
            "STAR_GAIN": 0.0, "EXPOSURE": 1.0,
        ]),
        ("Quasar", [
            "DISK_TEMP": 15000, "DISK_INCL": 1.30, "DISK_ROLL": 0.35,
            "DISK_INNER": 3.0, "DISK_OUTER": 14.0, "DISK_OPACITY": 0.35,
            "DOPPLER_MIX": 1.0, "DISK_BEAM": 4.0, "DISK_GAIN": 1.2,
            "DISK_CONTRAST": 1.3, "DISK_WIND": 8.0, "DISK_SPEED": 5.0,
            "STAR_GAIN": 0.0, "EXPOSURE": 0.8,
        ]),
        // violently hot and fast: a huge thin disk, heavily beamed
        ("Blazar", [
            "DISK_TEMP": 18000, "DISK_INCL": 0.30, "DISK_ROLL": 0.55,
            "DISK_INNER": 3.0, "DISK_OUTER": 16.0, "DISK_OPACITY": 0.30,
            "DOPPLER_MIX": 1.0, "DISK_BEAM": 5.0, "DISK_GAIN": 1.0,
            "DISK_CONTRAST": 1.5, "DISK_WIND": 9.0, "DISK_SPEED": 6.0,
            "STAR_GAIN": 0.0, "EXPOSURE": 0.75,
        ]),
        // no disk at all: just the shadow, the lensed starfield and the bent
        // screen — pure Schwarzschild geometry
        ("Pure lens", [
            "DISK_GAIN": 0.0, "DISK_OPACITY": 0.0, "STAR_GAIN": 0.6, 
            "DOPPLER_MIX": 1.0, "EXPOSURE": 1.0, "DISK_OUTER": 8.0,
        ]),
        // barely-there companion for focused work: dim, slow, no starfield
        ("Zen", [
            "DISK_TEMP": 7000, "DISK_INCL": 1.45, "DISK_ROLL": 0.15,
            "DISK_INNER": 3.5, "DISK_OUTER": 7.0, "DISK_OPACITY": 0.40,
            "DOPPLER_MIX": 0.5, "DISK_BEAM": 2.0, "DISK_GAIN": 0.5,
            "DISK_CONTRAST": 0.3, "DISK_WIND": 3.0, "DISK_SPEED": 1.5,
            "STAR_GAIN": 0.0, "EXPOSURE": 0.7,
        ]),
    ]
}

/// The live tunable set. The renderer reads it every frame, so a change lands
/// on the next frame with no recompile — which is the whole reason the GLSL's
/// `const float` block became uniforms in the port.
final class Params: ObservableObject {
    @Published var values: [String: Double]
    @Published var styleName: String

    private static let storeKey = "tunables"
    private static let styleKey = "style"

    init() {
        var v = Specs.defaults
        if let saved = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: Double] {
            for (k, val) in saved where Specs.all[k] != nil { v[k] = val }
        }
        values = v
        styleName = UserDefaults.standard.string(forKey: Self.styleKey) ?? Specs.styles[0].0
    }

    subscript(name: String) -> Double {
        get { values[name] ?? Specs.spec(name).def }
        set { values[name] = newValue }
    }

    func apply(style name: String) {
        guard let style = Specs.styles.first(where: { $0.0 == name }) else { return }
        for (k, v) in style.1 where Specs.all[k] != nil { values[k] = v }
        styleName = name
        UserDefaults.standard.set(name, forKey: Self.styleKey)
        save()
    }

    func resetAll() {
        values = Specs.defaults
        save()
    }

    func save() { UserDefaults.standard.set(values, forKey: Self.storeKey) }

    /// Shadow radius as a fraction of the widget's height, after the shader's
    /// per-style shrink. Mirrors the size block in BlackHole.metal — the
    /// infall animation has to know where the horizon actually is on screen,
    /// which is the one thing the CPU cannot read back out of the shader.
    /// `PANEL_DISK_ROOM` there and the constant here must move together.
    func shadowRadiusFraction() -> Double {
        let rin = max(self["DISK_INNER"], 1.6)
        let rout = max(self["DISK_OUTER"], rin + 0.5)
        var rh = max(self["HOLE_FILL"], 1e-4)
        let bCrit = 2.5980762
        let diskExtent = (rout / bCrit) * rh
        let room = 0.34
        if diskExtent > room { rh *= room / diskExtent }
        return rh
    }

    /// Snapshot the tunables into the GPU struct. Resolution, the background
    /// fit and `skyAlpha` are supplied by the renderer.
    func uniforms(time: Float, diskPhase: Float, width: Float, height: Float,
                  bgFit: BackgroundFit, skyAlpha: Float,
                  flare: Float, audio: Float, drift: SIMD2<Float>) -> Uniforms {
        func f(_ k: String) -> Float { Float(self[k]) }
        var u = Uniforms()
        u.time = time
        u.resX = width
        u.resY = height
        u.holeFill = f("HOLE_FILL")

        u.lensDepth   = f("LENS_DEPTH")
        u.lensFalloff = f("LENS_FALLOFF")
        u.starGain    = f("STAR_GAIN")
        u.diskPhase   = diskPhase

        u.diskInner = f("DISK_INNER")
        u.diskOuter = f("DISK_OUTER")
        u.diskIncl  = f("DISK_INCL")
        u.diskRoll  = f("DISK_ROLL")

        u.diskGain    = f("DISK_GAIN")
        u.diskOpacity = f("DISK_OPACITY")
        u.diskTemp    = f("DISK_TEMP")
        u.dopplerMix  = f("DOPPLER_MIX")

        u.diskBeam     = f("DISK_BEAM")
        u.diskSpeed    = f("DISK_SPEED")
        u.diskWind     = f("DISK_WIND")
        u.diskContrast = f("DISK_CONTRAST")

        u.exposure = f("EXPOSURE")
        u.flare    = flare
        u.nSteps   = f("N_STEPS")
        u.bgDim    = f("BG_DIM")

        u.bgScaleX = bgFit.scaleX
        u.bgScaleY = bgFit.scaleY
        u.bgOffX   = bgFit.offX
        u.bgOffY   = bgFit.offY
        u.skyAlpha   = skyAlpha
        u.audio      = audio
        u.spotGain   = f("SPOT_GAIN")
        u.spotRadius = f("SPOT_RADIUS")
        u.driftX     = drift.x
        u.driftY     = drift.y
        // Mass just fell in, so the hole is briefly heavier and bends harder.
        u.lensBoost  = 1 + 0.12 * flare
        u.ringGain   = f("RING_GAIN")
        return u
    }
}
