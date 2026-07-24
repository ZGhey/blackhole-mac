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

    /// The debris that has joined the disk: when it arrived, where round the
    /// disk, and what it used to look like.
    private var fedAt: CFTimeInterval?
    private var fedAngle: Float = 0
    private var fedColour = SIMD3<Float>(1, 1, 1)

    /// How long the disk stays visibly fed. A real tidal disruption flare runs
    /// for months; a few seconds is the same shape at a watchable rate.
    private static let feedDecay: Double = 3.2
    private static let feedLifetime: Double = 14

    /// Sharp enough to read as an impact rather than a fade-in.
    private static let attack: Double = 0.06
    /// Long enough to watch it settle, short enough not to linger.
    private static let decay: Double = 0.9
    /// Past this the envelope is below a percent and the event is dead weight.
    private static let lifetime: Double = 4.0

    func strike() {
        events.append(CACurrentMediaTime())
    }

    /// The stream reached the disk. From here the swallowed thing *is* disk.
    func deliver(angle: Float, colour: SIMD3<Float>) {
        fedAt = CACurrentMediaTime()
        fedAngle = angle
        fedColour = colour
    }

    /// Strength decays; the bright patch also spreads round the disk as it
    /// circularises, which the shader derives from the same number.
    func feed() -> (angle: Float, strength: Float, colour: SIMD3<Float>) {
        guard let fedAt else { return (0, 0, .one) }
        let x = CACurrentMediaTime() - fedAt
        if x > Self.feedLifetime {
            self.fedAt = nil
            return (0, 0, .one)
        }
        return (fedAngle, Float(exp(-x / Self.feedDecay)), fedColour)
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
