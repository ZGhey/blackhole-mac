import Foundation

/// Display metadata for one tunable, for the Advanced sheet. Ported from the
/// Ghostty tuner's ParamSpec.swift — same names, so its presets paste straight in.
public struct ParamSpec {
    public let range: ClosedRange<Double>
    public let group: String
    public let help: String
    public let def: Double

    public init(_ range: ClosedRange<Double>, _ group: String, _ def: Double, _ help: String) {
        self.range = range
        self.group = group
        self.def = def
        self.help = help
    }
}

public enum Specs {
    public static let groupOrder = ["Black hole", "Accretion disk", "Color & light", "Render"]

    /// Order within each group, since a dictionary has none.
    public static let order: [String] = [
        "HALO", "LENS_DEPTH", "LENS_FALLOFF", "STAR_GAIN", "DRIFT", "DRIFT_SPEED",
        "DISK_INNER", "DISK_OUTER", "DISK_INCL", "DISK_ROLL",
        "DISK_GAIN", "DISK_OPACITY", "DISK_SPEED", "DISK_WIND", "DISK_CONTRAST", "PLUNGE",
        "SPOT_GAIN", "SPOT_RADIUS",
        "DISK_TEMP", "DOPPLER_MIX", "DISK_BEAM", "EXPOSURE", "RING_GAIN",
        "DISK_RATE", "DISK_REFRESH",
        "BLOOM", "BLOOM_THRESHOLD", "N_STEPS", "BG_DIM", "BG_BLUR",
    ]

    public static let all: [String: ParamSpec] = [
        "HALO":          ParamSpec(1.0...2.6, "Black hole", 1.25, "How much lensed background rings the disk, as a multiple of the disk's own radius. 1.0 is the warp hugging it exactly. The composition always fills the widget, so this sets the proportions and the Size menu sets how big — they no longer fight"),
        "LENS_DEPTH":    ParamSpec(0.0...20.0, "Black hole", 13.0, "Distance from the hole to the screen behind it, in Schwarzschild radii — bigger bends what's behind harder"),
        "LENS_FALLOFF":  ParamSpec(1.2...40.0, "Black hole", 2.0, "How far the lensing reaches, in shadow radii. Real bending falls off as 1/b and never stops; this fades it out. Pull it in and the warp hugs the ring instead of filling the widget — but raise DISK_ROOM with it, or the space it vacates is left as a near-undistorted copy of the screen rather than as ring"),
        "DRIFT":         ParamSpec(0.0...0.12, "Black hole", 0.05, "How far the hole wanders inside the widget, as a fraction of its height. The lensed halo is a static mapping of whatever is behind — it only moves when the warp field itself does, so this is the only thing keeping the outer rings alive. Past ~0.06 the disk's outer edge starts running into the silhouette's taper"),
        "DRIFT_SPEED":   ParamSpec(0.0...3.0, "Black hole", 2.0, "How fast it wanders. The path is two incommensurate sines per axis, so it never repeats"),
        "STAR_GAIN":     ParamSpec(0.0...2.0, "Black hole", 0.0, "Brightness of the lensed starfield (0 = off). Worth raising when the screen is not being recorded, where there is nothing else to bend"),

        "DISK_INNER":    ParamSpec(1.6...8.0, "Accretion disk", 1.8, "Inner edge in Schwarzschild radii; 3 is the ISCO (innermost stable circular orbit)"),
        "DISK_OUTER":    ParamSpec(4.0...20.0, "Accretion disk", 8.0, "Outer edge in Schwarzschild radii. The hole is scaled down automatically if this would push the disk past the widget's edge"),
        "DISK_INCL":     ParamSpec(0.0...1.5707, "Accretion disk", 1.5, "Inclination in radians: 0 = face-on, π/2 = edge-on (the Interstellar look)"),
        "DISK_ROLL":     ParamSpec(-3.1416...3.1416, "Accretion disk", 0.35, "Rotation of the whole system in the screen plane, radians"),
        "DISK_GAIN":     ParamSpec(0.0...4.0, "Accretion disk", 2.2, "Disk emission brightness"),
        "DISK_OPACITY":  ParamSpec(0.0...1.0, "Accretion disk", 0.9, "How much the near disk hides the shadow, the far-side images and the screen behind it"),
        "DISK_SPEED":    ParamSpec(-10.0...10.0, "Accretion disk", 5.0, "Streak pattern speed; negative reverses the orbital direction"),
        "DISK_WIND":     ParamSpec(0.0...15.0, "Accretion disk", 7.0, "Spiral winding tightness of the streaks"),
        "DISK_CONTRAST": ParamSpec(0.0...2.0, "Accretion disk", 1.6, "Streak contrast: 0 = smooth haze, higher = sharp filaments"),
        "PLUNGE":        ParamSpec(0.0...1.5, "Accretion disk", 0.55, "How brightly the plunging region inside the ISCO still radiates. Matter there cannot hold a circular orbit and falls, but it does not stop glowing — 0 restores the hard geometric rim at DISK_INNER"),
        "SPOT_GAIN":     ParamSpec(0.0...4.0, "Accretion disk", 1.8, "Brightness of an orbiting hot spot — a compact overdensity on a near-ISCO orbit, the same picture used to model Sgr A*'s infrared flares. 0 turns it off. It is what gives the ring a feature you can actually watch go round"),
        "SPOT_RADIUS":   ParamSpec(1.8...8.0, "Accretion disk", 2.4, "Which orbit the hot spot rides, in Schwarzschild radii. Closer in is faster and more strongly beamed, and lenses harder over the shadow"),

        "DISK_TEMP":     ParamSpec(2000.0...20000.0, "Color & light", 5500.0, "Blackbody temperature of the hottest annulus, Kelvin"),
        "DOPPLER_MIX":   ParamSpec(0.0...1.0, "Color & light", 0.6, "Relativistic Doppler shift + beaming asymmetry: 0 = off, 1 = full physics"),
        "DISK_BEAM":     ParamSpec(0.0...6.0, "Color & light", 2.5, "Beaming exponent: observed intensity scales as g^N (3 ≈ photon-count, 4 ≈ bolometric)"),
        "RING_GAIN":     ParamSpec(0.0...4.0, "Color & light", 1.2, "Extra brightness for the photon ring — the stack of higher-order images made by rays that wound around the photon sphere. It is the sharpest structure in the picture and the faintest, so the disk's own glow buries it without this"),
        "EXPOSURE":      ParamSpec(0.05...5.0, "Color & light", 1.4, "Tonemap exposure for the disk light; the screen behind is never tonemapped"),

        "DISK_RATE":     ParamSpec(0.0...1.0, "Render", 0.35, "How fast the disk turns overall — the gravitational time dilation theme. Lower reads as heavier"),
        "DISK_REFRESH":  ParamSpec(4.0...90.0, "Render", 26.0, "How many seconds of shear the streak pattern may build up before it is quietly replaced. The gas at the inner edge orbits far faster than the outer edge, so any pattern painted on it winds into an ever-tighter spiral — left unbounded the filaments disappear below the pixel grid within a couple of minutes and the disk becomes fine noise. Lower churns visibly; higher lets it wind further before refreshing"),
        "BLOOM":         ParamSpec(0.0...2.0, "Render", 0.35, "How much bright light spills into its surroundings. 0 skips the four extra passes entirely — it is what makes the disk read as bright rather than merely pale. Too much and the disk spills onto itself, which costs it every filament"),
        "BLOOM_THRESHOLD": ParamSpec(0.2...1.0, "Render", 0.85, "How bright a pixel must be before it starts to glow. Most of the disk sits around 0.7, so anything much below that blooms the disk into its own neighbours and flattens the streaks into one sheet — this wants to catch the inner edge and the photon ring, not the whole thing"),
        "N_STEPS":       ParamSpec(8...128, "Render", 48, "Geodesic integration steps per pixel — the main GPU dial. Only pixels near the hole pay it"),
        "BG_DIM":        ParamSpec(0.0...1.0, "Render", 1.0, "Dims the lensed screen so the disk reads brighter against busy content"),
        "BG_BLUR":       ParamSpec(0.0...3.0, "Render", 1.5, "Softens the lensed screen in proportion to how hard the lens is squeezing it — the corners stay pixel-exact, the compressed band around the ring turns to glow. 0 is the honest sample, which over a page of text reproduces every line of it a pixel apart"),
    ]

    public static func spec(_ name: String) -> ParamSpec {
        all[name] ?? ParamSpec(0...1, "Render", 0, "")
    }

    public static var defaults: [String: Double] { all.mapValues(\.def) }

    public static func grouped() -> [(String, [String])] {
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
    ///
    /// `check-render` measures every entry here, so a style added to this list
    /// is covered by the winding and clipping trip wires without anyone having
    /// to remember it.
    public static let styles: [(String, [String: Double])] = [
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
