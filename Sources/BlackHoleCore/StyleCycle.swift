import Foundation

/// How often the widget moves on to the next style.
public enum CycleInterval: String, CaseIterable, Identifiable, Sendable {
    case off, hourly, daily

    public var id: String { rawValue }
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
/// The two intervals count from different origins on purpose. Hourly counts UTC
/// hours, which is the local hour everywhere but a handful of half-hour-offset
/// zones, and which daylight saving cannot perturb because the epoch has never
/// heard of it. Daily counts local midnights through `Calendar`, because a day
/// that turned over at 8am would not read as "daily" to anybody. The cost is
/// that a DST transition makes one local day 23 or 25 hours long — invisible at
/// one switch a day, and a doubled or skipped style at one switch an hour, which
/// is exactly why hourly does not use the calendar.
public enum StyleCycle {
    /// Index into the rotation for `date`, or nil when nothing is rotating.
    public static func index(at date: Date, interval: CycleInterval,
                             count: Int, calendar: Calendar = .current) -> Int? {
        guard count > 0, let slot = slot(at: date, interval: interval, calendar: calendar)
        else { return nil }
        // Swift's % takes the sign of the dividend and slots before 1970 are
        // negative, so the remainder has to be folded back into range.
        return ((slot % count) + count) % count
    }

    /// The instant the next style takes over, or nil when nothing is rotating.
    /// Always strictly after `date`, including when `date` sits exactly on a
    /// boundary — a timer scheduled for "now" would fire in a loop.
    public static func nextBoundary(after date: Date, interval: CycleInterval,
                                    calendar: Calendar = .current) -> Date? {
        switch interval {
        case .off:
            return nil
        case .hourly:
            let hours = (date.timeIntervalSince1970 / 3600).rounded(.down)
            return Date(timeIntervalSince1970: (hours + 1) * 3600)
        case .daily:
            return calendar.date(byAdding: .day, value: 1,
                                 to: calendar.startOfDay(for: date))
        }
    }

    /// Which slot of the rotation `date` falls in, counted from the origin.
    private static func slot(at date: Date, interval: CycleInterval,
                             calendar: Calendar) -> Int? {
        switch interval {
        case .off:
            return nil
        case .hourly:
            return Int((date.timeIntervalSince1970 / 3600).rounded(.down))
        case .daily:
            let origin = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
            return calendar.dateComponents([.day], from: origin,
                                           to: calendar.startOfDay(for: date)).day
        }
    }
}
