import BlackHoleCore
import AppKit
import SwiftUI

/// Moves the widget on to the next style every hour, or every day.
///
/// The rotation itself is `StyleCycle` in BlackHoleCore, which is a pure
/// function of the clock — this is the shell that owns the selection, schedules
/// the switch, and asks the panel to hide the seam. Nothing about *where in the
/// rotation we are* is stored: the timer exists to notice the boundary, not to
/// count. Miss a hundred of them and the next `sync` still lands on the right
/// style.
///
/// The trap this class is built around: the cycler applies styles through the
/// same `Params.apply(style:)` the menu does, and a manual style change is
/// supposed to turn cycling off. So the stopping lives at the *call sites the
/// human touches* — the menu's style buttons, the Advanced panel's sliders —
/// and never in here. Putting it in `Params` would have the cycle switch itself
/// off the first time it fired.
@MainActor
final class StyleCycler: ObservableObject {
    private let params: Params
    private var timer: Timer?
    /// True while nobody can see the widget. Parked, the switch timer is not
    /// worth holding: the clock is the state, so unparking recovers the right
    /// style on its own.
    private var suspended = true

    private static let intervalKey = "cycleInterval"
    private static let selectionKey = "cycleStyles"
    private static let anchorKey = "cycleAnchor"

    /// The slot the rotation counts from, so that switching the cycle on starts
    /// at the first selected style instead of wherever the bare clock happened
    /// to be. Re-taken when the cycle is switched on and when the interval
    /// changes — an anchor is in the interval's own units and means nothing in
    /// anybody else's. Deliberately *not* re-taken when the selection changes:
    /// unticking a style you are not looking at should not throw you back to
    /// the top of the list.
    private var anchor: Int

    @Published var interval: CycleInterval {
        didSet {
            guard interval != oldValue else { return }
            UserDefaults.standard.set(interval.rawValue, forKey: Self.intervalKey)
            reanchor()
            // Landing on the first style is the whole point; waiting up to an
            // hour to find out whether the setting did anything is not.
            restart(animated: true)
        }
    }

    /// Which styles take part. Held as names rather than indices so that saving,
    /// renaming or deleting a custom style cannot silently re-point it at
    /// somebody else's look.
    @Published private(set) var selected: Set<String>

    /// Set by the delegate. Runs the swap behind the panel's fade; a direct call
    /// when there is no panel to fade.
    var performSwitch: ((@escaping () -> Void) -> Void)?

    init(params: Params) {
        self.params = params
        let d = UserDefaults.standard
        // Through a local: reading `self.interval` back here is reading a
        // property of a half-initialized object, which the compiler is right to
        // refuse.
        let restored = (d.string(forKey: Self.intervalKey)
                            .flatMap(CycleInterval.init(rawValue:))) ?? .off
        interval = restored
        // A cycle left running by an older build has no anchor stored. Taking
        // one now rather than defaulting to zero means it starts from the top
        // on this launch, which is the behaviour the anchor exists to give —
        // and it has to be *written*, or every launch would take a fresh one
        // and the rotation would restart from the top every time the app did.
        let stored = d.object(forKey: Self.anchorKey) as? Int
        let resolved = stored ?? StyleCycle.slot(at: Date(), interval: restored) ?? 0
        anchor = resolved
        if stored == nil && restored != .off {
            d.set(resolved, forKey: Self.anchorKey)
        }
        // No stored selection means nobody has ever opened this menu, and an
        // empty rotation would make turning cycling on do nothing at all. Every
        // style is the only default that shows what the feature is.
        if let stored = d.stringArray(forKey: Self.selectionKey) {
            selected = Set(stored)
        } else {
            selected = Set(Specs.styles.map(\.0) + params.customStyleNames)
        }
    }

    // ----------------------------------------------------------- selection --

    /// Built-ins in the order `Specs.styles` declares them, then custom styles.
    /// Fixed, because the index is derived from the clock: a shuffled rotation
    /// would need a stored seed and a stored cursor, and this needs neither.
    var allStyleNames: [String] { Specs.styles.map(\.0) + params.customStyleNames }

    var rotation: [String] { allStyleNames.filter { selected.contains($0) } }

    func toggle(_ name: String) {
        if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
        selectionChanged()
    }

    func selectAll() {
        selected = Set(allStyleNames)
        selectionChanged()
    }

    func selectNone() {
        selected = []
        selectionChanged()
    }

    /// A style you just saved is one you want to see, so it joins the rotation.
    /// It joins the *selection* even when cycling is off — the selection is
    /// remembered for the next time it is turned on.
    func styleAdded(_ name: String) {
        selected.insert(name)
        selectionChanged()
    }

    func styleRemoved(_ name: String) {
        guard selected.remove(name) != nil else { return }
        selectionChanged()
    }

    private func selectionChanged() {
        UserDefaults.standard.set(Array(selected).sorted(), forKey: Self.selectionKey)
        // Nothing left to rotate through. Turning the cycle off says so; greying
        // the last check box out would only leave somebody clicking at it.
        if interval != .off && rotation.isEmpty {
            interval = .off        // didSet restarts
            return
        }
        restart(animated: true)
    }

    // -------------------------------------------------------- user control --

    /// The human picked a style, or moved a slider. Direct action wins: leaving
    /// the cycle running would take their choice away again at the next
    /// boundary, with nothing on screen to explain why.
    func stop() {
        guard interval != .off else { return }
        interval = .off
    }

    // ------------------------------------------------------------ movement --

    /// Count from here, so the next thing shown is the first selected style.
    private func reanchor() {
        guard interval != .off,
              let slot = StyleCycle.slot(at: Date(), interval: interval) else { return }
        anchor = slot
        UserDefaults.standard.set(slot, forKey: Self.anchorKey)
    }

    /// Catch up to the clock and re-aim the timer at the next boundary. Every
    /// change of interval, selection or parked state wants exactly this pair,
    /// and in this order: the style first, so the widget is never showing the
    /// wrong one while it waits.
    private func restart(animated: Bool) {
        sync(animated: animated)
        reschedule()
    }

    /// Put the widget on whatever style this instant calls for.
    private func sync(animated: Bool) {
        guard interval != .off, !suspended else { return }
        let names = rotation
        guard let i = StyleCycle.index(at: Date(), interval: interval,
                                       count: names.count, anchor: anchor),
              names[i] != params.styleName
        else { return }
        let target = names[i]
        if animated, let performSwitch {
            performSwitch { [weak self] in self?.params.apply(style: target) }
        } else {
            params.apply(style: target)
        }
    }

    /// Parked and unparked with everything else the widget stops when nobody is
    /// looking. Unparking applies the current style *without* the fade — the
    /// panel is already fading in around it, and two crossfades over each other
    /// is a flicker.
    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        if value {
            timer?.invalidate()
            timer = nil
        } else {
            restart(animated: false)
        }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard !suspended, interval != .off,
              let next = StyleCycle.nextBoundary(after: Date(), interval: interval)
        else { return }
        // One shot to the boundary rather than a repeating timer: a repeating
        // one drifts, and after a sleep it fires immediately for every boundary
        // it missed.
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restart(animated: true)
            }
        }
        // The common mode, or the switch would not happen while a menu is open.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

extension CycleInterval {
    var label: String {
        switch self {
        case .off:            return L("menu.cycle.off")
        case .fiveMinutes:    return L("menu.cycle.5m")
        case .thirtyMinutes:  return L("menu.cycle.30m")
        case .hourly:         return L("menu.cycle.hourly")
        case .daily:          return L("menu.cycle.daily")
        }
    }
}
