import Foundation

/// The tunable set as a value.
///
/// `Params` in the app wraps one of these in an `ObservableObject` so the
/// sliders can publish; nothing below that shell needs to know a publisher
/// exists. Keeping the values separate is what lets the offscreen tools build
/// the same uniforms the app does without dragging SwiftUI in behind them.
public struct Tunables {
    public private(set) var values: [String: Double]

    public init(_ values: [String: Double] = Specs.defaults) {
        self.values = values
    }

    public subscript(name: String) -> Double {
        get { values[name] ?? Specs.spec(name).def }
        set { values[name] = newValue }
    }

    /// Overlay a style's patch. Unknown keys are dropped rather than stored, so
    /// a preset written against an older build cannot smuggle in a dead name.
    public mutating func apply(_ patch: [String: Double]) {
        for (k, v) in patch where Specs.all[k] != nil { values[k] = v }
    }

    public func applying(_ patch: [String: Double]) -> Tunables {
        var copy = self
        copy.apply(patch)
        return copy
    }

    public mutating func reset() { values = Specs.defaults }

    // ---------------------------------------------------------- geometry --

    /// Radius of everything the widget draws, as a fraction of its height —
    /// `halo` times the fitted ring extent, capped where the shader caps it.
    /// The click region is defined against this, so the widget only swallows
    /// clicks where there is something to click on.
    public func haloRadiusFraction() -> Double { 0.49 }   // PANEL_FADE_MAX

    /// Shadow radius as a fraction of the widget's height, after the shader's
    /// per-style shrink. Mirrors the size block in BlackHole.metal — the
    /// infall animation has to know where the horizon actually is on screen,
    /// which is the one thing the CPU cannot read back out of the shader.
    /// `PANEL_DISK_ROOM` there and the constant here must move together.
    public func shadowRadiusFraction() -> Double {
        let rin = max(self["DISK_INNER"], 1.6)
        let rout = max(self["DISK_OUTER"], rin + 0.5)
        let lit = rin + (rout - rin) * 0.78          // matches `lit` in the shader
        let halo = min(max(self["HALO"], 1.0), 3.0)
        return (0.49 / halo) * 2.5980762 / lit
    }
}
