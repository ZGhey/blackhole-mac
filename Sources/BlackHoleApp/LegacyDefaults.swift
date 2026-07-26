import Foundation

/// Carry the saved settings across the one time the bundle identifier changed.
///
/// `UserDefaults.standard` is keyed to the bundle identifier, so renaming the
/// bundle hands the app an empty store: tuned parameters gone, saved styles
/// gone, the widget back in the default corner. TCC and `SMAppService` are keyed
/// to it as well and cannot be migrated at all — Screen Recording has to be
/// granted again, and launch-at-login re-registered — but preferences can, and
/// losing a style somebody built by hand is the part that would actually sting.
///
/// Runs once. After it, the old domain is left alone rather than deleted: it
/// costs nothing, and an old copy of the app on the same Mac keeps working.
enum LegacyDefaults {
    private static let oldDomain = "dev.s13k.blackhole-app"
    /// Present exactly when this app has saved something of its own, so the
    /// absence of it is what "never launched under the new identifier" means.
    private static let sentinel = "tunables"

    static func migrateIfNeeded() {
        let now = UserDefaults.standard
        guard now.object(forKey: sentinel) == nil,
              let old = UserDefaults(suiteName: oldDomain),
              old.object(forKey: sentinel) != nil
        else { return }

        // Only the keys still read. The settings that lost their menu items are
        // pinned to their defaults now, so bringing their old values across
        // would restore something nobody can see or change.
        //
        // "lens" is read again and still deliberately absent: TCC is keyed to
        // the bundle identifier and cannot be migrated, so a rename revokes
        // Screen Recording no matter what. Carrying `.screen` across would have
        // the widget reach for a capture it no longer has permission for on the
        // first launch, which is exactly the prompt this app now waits to be
        // asked for. Left out, the preflight in AppModel sees the truth — not
        // granted — and comes up quiet with the offer in the menu.
        var keys = ["tunables", "style", "customStyles", "size", "hidden", "lastDisplay"]
        // Positions are per display, so the key names are not known in advance.
        keys += old.dictionaryRepresentation().keys.filter { $0.hasPrefix("origin-") }

        for key in keys {
            guard let value = old.object(forKey: key) else { continue }
            now.set(value, forKey: key)
        }
    }
}
