import Foundation

/// Whatever occupies the sky-plane sprite slot this frame — a dropped file, or
/// the pointer's own image. Which of them wins is the renderer's business; by
/// the time it reaches here the argument is over.
public struct Sprite {
    public var centre: SIMD2<Float>
    public var size: Float
    public var alpha: Float
    public var tear: Float

    public init(centre: SIMD2<Float>, size: Float, alpha: Float, tear: Float) {
        self.centre = centre
        self.size = size
        self.alpha = alpha
        self.tear = tear
    }
}

/// Debris that has joined the disk: where round it, how brightly it is still
/// glowing, and what colour it used to be.
public struct Feed {
    public var angle: Float
    public var strength: Float
    public var colour: SIMD3<Float>

    public init(angle: Float = 0, strength: Float = 0, colour: SIMD3<Float> = .one) {
        self.angle = angle
        self.strength = strength
        self.colour = colour
    }
}

/// Everything a frame contributes that is not a tunable.
///
/// All of it is already resolved: the sprite slot has been won, the flare
/// envelope evaluated, the low-power step count taken from `SystemState`. This
/// type says *what is true this frame*, never *how it came to be*.
public struct FrameInputs {
    public var time: Float
    public var diskPhase: Float
    public var width: Float
    public var height: Float
    public var bgFit: BackgroundFit
    public var skyAlpha: Float
    public var flare: Float
    public var audio: Float
    public var hover: Float
    public var drift: SIMD2<Float>
    /// Already through `SystemState.steps(preferred:)`. Low power is a system
    /// policy and lives with the rest of that policy, not in here.
    public var nSteps: Float
    public var sprite: Sprite?
    public var feed: Feed

    public init(time: Float, diskPhase: Float, width: Float, height: Float,
                bgFit: BackgroundFit = BackgroundFit(), skyAlpha: Float = 1,
                flare: Float = 0, audio: Float = 0, hover: Float = 0,
                drift: SIMD2<Float> = SIMD2<Float>(0, 0), nSteps: Float = 48,
                sprite: Sprite? = nil, feed: Feed = Feed()) {
        self.time = time
        self.diskPhase = diskPhase
        self.width = width
        self.height = height
        self.bgFit = bgFit
        self.skyAlpha = skyAlpha
        self.flare = flare
        self.audio = audio
        self.hover = hover
        self.drift = drift
        self.nSteps = nSteps
        self.sprite = sprite
        self.feed = feed
    }

    /// A still frame with nothing falling in and nothing having been fed — what
    /// the offscreen tools render.
    public static func offscreen(_ t: Tunables, size: Int, phase: Float, time: Float = 3,
                                 bgFit: BackgroundFit = BackgroundFit(),
                                 skyAlpha: Float = 1) -> FrameInputs {
        FrameInputs(time: time, diskPhase: phase,
                    width: Float(size), height: Float(size),
                    bgFit: bgFit, skyAlpha: skyAlpha,
                    nSteps: Float(t["N_STEPS"]))
    }
}

/// The one place a `Uniforms` is filled in.
///
/// It used to be two: `Params` set 37 of the fields and `Renderer.draw` set the
/// other 11, and the two offscreen tools each retyped the whole thing as a
/// positional `[Float]` array that nothing checked. The struct's members are
/// `private(set)` so that cannot come back.
public enum FrameUniforms {
    public static func make(_ t: Tunables, _ f: FrameInputs) -> Uniforms {
        func v(_ k: String) -> Float { Float(t[k]) }
        var u = Uniforms()

        let w = max(f.width, 1), h = max(f.height, 1)
        u.time = f.time
        u.resX = w
        u.resY = h
        u.halo = v("HALO")

        u.lensDepth   = v("LENS_DEPTH")
        u.lensFalloff = v("LENS_FALLOFF")
        u.starGain    = v("STAR_GAIN")
        u.diskPhase   = f.diskPhase

        u.diskInner = v("DISK_INNER")
        u.diskOuter = v("DISK_OUTER")
        u.diskIncl  = v("DISK_INCL")
        u.diskRoll  = v("DISK_ROLL")

        u.diskGain    = v("DISK_GAIN")
        u.diskOpacity = v("DISK_OPACITY")
        u.diskTemp    = v("DISK_TEMP")
        u.dopplerMix  = v("DOPPLER_MIX")

        u.diskBeam     = v("DISK_BEAM")
        u.diskSpeed    = v("DISK_SPEED")
        u.diskWind     = v("DISK_WIND")
        u.diskContrast = v("DISK_CONTRAST")

        u.exposure = v("EXPOSURE")
        u.flare    = f.flare
        u.nSteps   = f.nSteps
        u.bgDim    = v("BG_DIM")

        u.bgScaleX = f.bgFit.scaleX
        u.bgScaleY = f.bgFit.scaleY
        u.bgOffX   = f.bgFit.offX
        u.bgOffY   = f.bgFit.offY

        u.skyAlpha   = f.skyAlpha
        u.audio      = f.audio
        u.spotGain   = v("SPOT_GAIN")
        u.spotRadius = v("SPOT_RADIUS")

        u.driftX = f.drift.x
        u.driftY = f.drift.y
        // Mass just fell in, so the hole is briefly heavier and bends harder.
        u.lensBoost = 1 + 0.12 * f.flare
        u.ringGain  = v("RING_GAIN")

        // The sprite is placed relative to the widget's centre, but the hole is
        // off there by the drift, and the shader's overlay is polar around the
        // hole. Aspect-correcting x is what keeps a dropped file round in a
        // window that is not.
        let sprite = f.sprite ?? Sprite(centre: SIMD2<Float>(0.5, 0.5), size: 0, alpha: 0, tear: 0)
        let aspect = w / h
        u.fallX     = (sprite.centre.x - 0.5 - f.drift.x) * aspect
        u.fallY     = sprite.centre.y - 0.5 - f.drift.y
        u.fallSize  = sprite.size
        u.fallAlpha = sprite.alpha

        u.hover    = f.hover
        u.fallTear = sprite.tear

        u.feedAngle    = f.feed.angle
        u.feedStrength = f.feed.strength
        u.feedR = f.feed.colour.x
        u.feedG = f.feed.colour.y
        u.feedB = f.feed.colour.z
        u.plunge = v("PLUNGE")

        u.bgBlur      = v("BG_BLUR")
        u.diskRefresh = v("DISK_REFRESH")

        return u
    }
}
