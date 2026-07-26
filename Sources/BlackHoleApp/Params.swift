import BlackHoleCore
import Foundation
import SwiftUI

/// The live tunable set, plus the publishing the sliders need.
///
/// The values themselves are a `Tunables` in BlackHoleCore — this is the shell
/// that persists them and tells SwiftUI when they move. The renderer reads it
/// every frame, so a change lands on the next frame with no recompile, which is
/// the whole reason the GLSL's `const float` block became uniforms in the port.
final class Params: ObservableObject {
    @Published private(set) var tunables: Tunables
    @Published var styleName: String
    /// Looks you saved yourself. With this many dials, the built-in styles are
    /// a starting point, not a menu — anything you tune is worth keeping.
    @Published private(set) var customStyles: [String: [String: Double]]

    private static let storeKey = "tunables"
    private static let styleKey = "style"
    private static let customKey = "customStyles"

    init() {
        var t = Tunables()
        if let saved = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: Double] {
            t.apply(saved)
        }
        tunables = t
        styleName = UserDefaults.standard.string(forKey: Self.styleKey) ?? Specs.styles[0].0
        customStyles = (UserDefaults.standard.dictionary(forKey: Self.customKey)
                        as? [String: [String: Double]]) ?? [:]
    }

    subscript(name: String) -> Double {
        get { tunables[name] }
        set { tunables[name] = newValue }
    }

    /// Custom styles are stored whole rather than as a sparse patch: a built-in
    /// only names what it cares about so the others compose, but a look you
    /// saved is the look you saw, and inheriting stray values from whatever was
    /// loaded before would not reproduce it.
    var customStyleNames: [String] { customStyles.keys.sorted() }

    func apply(style name: String) {
        if let custom = customStyles[name] {
            tunables.apply(custom)
        } else if let style = Specs.styles.first(where: { $0.0 == name }) {
            tunables.apply(style.1)
        } else {
            return
        }
        styleName = name
        UserDefaults.standard.set(name, forKey: Self.styleKey)
        save()
    }

    func saveCurrentStyle(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        customStyles[trimmed] = tunables.values
        UserDefaults.standard.set(customStyles, forKey: Self.customKey)
        styleName = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.styleKey)
    }

    func deleteStyle(named name: String) {
        guard customStyles.removeValue(forKey: name) != nil else { return }
        UserDefaults.standard.set(customStyles, forKey: Self.customKey)
        // Falling back has to *apply* the style, not just rename to it. Moving
        // `styleName` alone left the widget rendering the deleted look under a
        // tick that claimed it was showing Inferno — and anything that decides
        // whether to act by comparing against `styleName`, the style cycler
        // included, then believed the lie.
        if styleName == name { apply(style: Specs.styles[0].0) }
    }

    func resetAll() {
        tunables.reset()
        save()
    }

    func save() { UserDefaults.standard.set(tunables.values, forKey: Self.storeKey) }

    /// Radius of everything the widget draws, as a fraction of its height. The
    /// click region is defined against this — see `Tunables`.
    func haloRadiusFraction() -> Double { tunables.haloRadiusFraction() }

    /// Where the horizon actually lands on screen, for the infall animation.
    func shadowRadiusFraction() -> Double { tunables.shadowRadiusFraction() }
}
