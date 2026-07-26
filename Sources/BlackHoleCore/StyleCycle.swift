import Foundation

/// How often the widget moves on to the next style.
///
/// The raw values of `hourly` and `daily` are load-bearing — they are what is
/// already in anybody's `UserDefaults` — so the two short intervals were given
/// names of their own rather than renaming the ladder into something tidier.
public enum CycleInterval: String, CaseIterable, Identifiable, Sendable {
    case off, fiveMinutes = "5m", thirtyMinutes = "30m", hourly, daily

    public var id: String { rawValue }

    /// The interval as a fixed number of seconds, or nil where there isn't one.
    ///
    /// `daily` deliberately has none: a local day is 23 or 25 hours across a
    /// daylight-saving change, so it is counted in midnights instead. Every
    /// other rung divides an hour, which means counting seconds from the epoch
    /// lands them on the local clock's own boundaries — :00, :05, :30 — in every
    /// zone whose offset is a whole or half hour, without a calendar being
    /// involved and without daylight saving being able to shift them.
    public var seconds: TimeInterval? {
        switch self {
        case .off, .daily:      return nil
        case .fiveMinutes:      return 300
        case .thirtyMinutes:    return 1800
        case .hourly:           return 3600
        }
    }
}

/// Which style a rotation is on at a given instant, and when it next changes.
///
/// Deliberately a pure function of the clock rather than a counter that ticks:
/// the style showing is `floor(now / interval) mod n`, so there is no progress
/// to persist and none to catch up on. A Mac that slept for eight hours wakes
/// on the style it should be on rather than stepping through the eight it
/// missed, and a relaunch lands exactly where it left off without having stored
/// anything at all.
///
/// The rungs count from two different origins on purpose. Everything up to an
/// hour counts seconds from the epoch, which is immune to daylight saving —
/// the epoch has never heard of it — and which still lands on the local
/// clock's own boundaries anywhere the zone offset is a whole or half hour.
/// Daily counts local midnights through `Calendar`, because a day that turned
/// over at 8am would not read as "daily" to anybody. The cost is that a DST
/// transition makes one local day 23 or 25 hours long — invisible at one switch
/// a day, and a doubled or skipped style at one switch an hour, which is exactly
/// why the short rungs do not use the calendar.
public enum StyleCycle {
    /// Index into the rotation for `date`, or nil when nothing is rotating.
    ///
    /// `anchor` is the slot the rotation is counted from — pass the slot the
    /// cycle was switched on in and the first selected style is what comes up,
    /// rather than whichever one the bare clock happened to land on. It shifts
    /// *which* style is showing and nothing else: the boundaries are still the
    /// clock's own, so the switches stay on the hour, on :05, on :30 or at
    /// midnight, and the value is still derived rather than accumulated.
    public static func index(at date: Date, interval: CycleInterval, count: Int,
                             anchor: Int = 0, calendar: Calendar = .current) -> Int? {
        guard count > 0, let slot = slot(at: date, interval: interval, calendar: calendar)
        else { return nil }
        // Swift's % takes the sign of the dividend, and the difference is
        // negative for any date before the anchor, so the remainder has to be
        // folded back into range.
        return (((slot - anchor) % count) + count) % count
    }

    /// The instant the next style takes over, or nil when nothing is rotating.
    /// Always strictly after `date`, including when `date` sits exactly on a
    /// boundary — a timer scheduled for "now" would fire in a loop.
    public static func nextBoundary(after date: Date, interval: CycleInterval,
                                    calendar: Calendar = .current) -> Date? {
        switch interval {
        case .off:
            return nil
        case .daily:
            return calendar.date(byAdding: .day, value: 1,
                                 to: calendar.startOfDay(for: date))
        default:
            guard let step = interval.seconds else { return nil }
            let slots = (date.timeIntervalSince1970 / step).rounded(.down)
            return Date(timeIntervalSince1970: (slots + 1) * step)
        }
    }

    /// Which slot of the rotation `date` falls in, counted from the origin.
    ///
    /// Public because the anchor is one of these: switching the cycle on stores
    /// the slot it was switched on in, and `index` counts from there. The unit
    /// differs per interval — 5-minute blocks, hours, local days — so an anchor
    /// only means anything alongside the interval it was taken with, and
    /// changing the interval has to take a new one.
    public static func slot(at date: Date, interval: CycleInterval,
                            calendar: Calendar = .current) -> Int? {
        switch interval {
        case .off:
            return nil
        case .daily:
            let origin = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
            return calendar.dateComponents([.day], from: origin,
                                           to: calendar.startOfDay(for: date)).day
        default:
            guard let step = interval.seconds else { return nil }
            return Int((date.timeIntervalSince1970 / step).rounded(.down))
        }
    }
}
