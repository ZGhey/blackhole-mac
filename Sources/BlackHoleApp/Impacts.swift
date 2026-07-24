import Foundation
import QuartzCore

/// Accretion flares: the disk's reaction to swallowing something.
///
/// Infalling matter really does light a disk up — the potential energy it gives
/// up on the way in is where a quasar's luminosity comes from. Without this the
/// widget eats a file and the disk does not so much as flicker, which is the
/// one moment it obviously should.
@MainActor
final class Impacts {
    static let shared = Impacts()

    /// Times at which a mass crossed the horizon.
    private var events: [CFTimeInterval] = []

    /// Sharp enough to read as an impact rather than a fade-in.
    private static let attack: Double = 0.06
    /// Long enough to watch it settle, short enough not to linger.
    private static let decay: Double = 0.9
    /// Past this the envelope is below a percent and the event is dead weight.
    private static let lifetime: Double = 4.0

    func strike() {
        events.append(CACurrentMediaTime())
    }

    /// Combined envelope, 0…~1.4. Several files dropped together stack, which
    /// is the right behaviour: more mass, more light.
    func level() -> Float {
        let now = CACurrentMediaTime()
        events.removeAll { now - $0 > Self.lifetime }
        guard !events.isEmpty else { return 0 }
        var total = 0.0
        for start in events {
            let x = now - start
            guard x >= 0 else { continue }
            total += exp(-x / Self.decay) * (1 - exp(-x / Self.attack))
        }
        return Float(min(total, 1.4))
    }
}
