import Foundation
import Metal
import MetalKit

enum RendererError: LocalizedError {
    case noDevice
    case noCommandQueue
    case noSampler
    case shaderNotFound
    case missingFunctions

    var errorDescription: String? {
        switch self {
        case .noDevice:         return "No Metal device — this Mac cannot run the renderer."
        case .noCommandQueue:   return "Could not create a Metal command queue."
        case .noSampler:        return "Could not create the background sampler."
        case .shaderNotFound:   return "BlackHole.metal is missing from the app bundle."
        case .missingFunctions: return "BlackHole.metal has no blackholeVertex/blackholeFragment."
        }
    }
}

/// Drives the Metal pass: one fullscreen triangle, one fragment shader, one
/// uniform struct per frame. There is no geometry and no render graph — the
/// whole image is the fragment shader, exactly as it was in Ghostty.
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let placeholder: MTLTexture

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let bloom: BloomChain

    /// Written from the UI on the main thread; `draw(in:)` also runs on the
    /// main thread (MTKView's display link targets the main run loop), so these
    /// need no synchronization.
    var params: Params
    var lens: LensSource = .screen

    /// A mipmapped copy of the current capture frame.
    ///
    /// Frames arrive from CVMetalTextureCache with a single level, and a single
    /// level is exactly what makes a lensed image alias: the shader asks for a
    /// footprint spanning dozens of texels and there is nothing to give it but
    /// the top mip. One blit and a mip chain per frame is cheap next to what it
    /// buys.
    private var mipped: MTLTexture?

    private var time: Float = 0
    private var diskPhase: Float = 0
    private var driftClock: Float = 0
    private var lastDraw = CACurrentMediaTime()

    init(device: MTLDevice, params: Params) throws {
        guard let queue = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        let library = try Self.makeLibrary(device: device)
        guard let vs = library.makeFunction(name: "blackholeVertex"),
              let fs = library.makeFunction(name: "blackholeFragment")
        else { throw RendererError.missingFunctions }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        // Deliberately not an *_srgb format: the shader tonemaps and composites
        // in the same raw-sRGB space the capture arrives in, which is what the
        // Ghostty original got from the terminal for free.
        desc.colorAttachments[0].pixelFormat = BloomChain.format
        desc.colorAttachments[1].pixelFormat = BloomChain.format
        // The widget emits premultiplied alpha so the parts of the frame it
        // does not touch stay see-through.
        let a = desc.colorAttachments[0]!
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add
        a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one            // already premultiplied
        a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        // mirrorUV already folds samples back into 0…1, so the address mode
        // only ever matters for the half-texel at the very edge.
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { throw RendererError.noSampler }

        self.bloom = try BloomChain(device: device, library: library)

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
        self.params = params
        self.placeholder = PlaceholderTexture.make(device: device)
        super.init()
    }

    /// Compiles BlackHole.metal at launch. SwiftPM has no .metal build rule for
    /// an executableTarget, so the shader travels as a resource — which is the
    /// better trade anyway: the source is right there to edit, and a relaunch
    /// (or BLACKHOLE_METAL pointing at a working copy) is the whole edit loop.
    /// Cached: one Renderer per screen means one desktop window per screen, and
    /// compiling the same source three times for a three-display setup is a
    /// pure waste of launch time.
    private static var cachedLibrary: MTLLibrary?

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let cachedLibrary { return cachedLibrary }
        let url = ProcessInfo.processInfo.environment["BLACKHOLE_METAL"].map(URL.init(fileURLWithPath:))
            ?? Bundle.module.url(forResource: "BlackHole", withExtension: "metal")
        guard let url, let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw RendererError.shaderNotFound
        }
        let library = try device.makeLibrary(source: source, options: nil)
        cachedLibrary = library
        return library
    }

    /// Copy this frame into a mipmapped texture and build the chain. Returns
    /// nil if the texture could not be allocated, in which case the caller
    /// falls back to the flat capture and simply aliases.
    private func mipmapped(_ source: MTLTexture, in buffer: MTLCommandBuffer) -> MTLTexture? {
        if mipped?.width != source.width || mipped?.height != source.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: source.pixelFormat, width: source.width,
                height: source.height, mipmapped: true)
            d.usage = [.shaderRead, .renderTarget]
            d.storageMode = .private
            mipped = device.makeTexture(descriptor: d)
        }
        guard let mipped, let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: mipped, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: mipped)
        blit.endEncoding()
        return mipped
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastDraw, 0), 0.1)   // clamp: a stalled frame must not jump the animation
        lastDraw = now
        time += Float(dt)

        // Flares and audio modulate how fast the disk turns, so the phase is
        // integrated here rather than derived from `time` in the shader — a
        // rate change applied to a large `time` would jump every streak at once.
        let (flare, audio, hover, reduceMotion, lowPower) = MainActor.assumeIsolated {
            () -> (Float, Float, Float, Bool, Bool) in
            Proximity.shared.step(shadowRadius: Float(params.shadowRadiusFraction()))
            return (Impacts.shared.level(),
                    ScreenCapture.shared.capturesAudio ? ScreenCapture.shared.audioLevel : 0,
                    Proximity.shared.hover,
                    SystemState.shared.reduceMotion, SystemState.shared.lowPower)
        }
        let rate = Float(abs(params["DISK_SPEED"]) * params["DISK_RATE"])
        diskPhase += Float(dt) * rate * (1 + 1.2 * flare + 0.5 * audio)

        // The GLSL's Lissajous, moved to the CPU with the rest of the motion.
        // Two incommensurate sines per axis: the orbit never visibly repeats.
        driftClock += Float(dt) * Float(params["DRIFT_SPEED"])
        // Reduce Motion stops the widget travelling. The disk still turns —
        // that is what it is, not incidental movement.
        let amp = reduceMotion ? 0 : Float(params["DRIFT"])
        let k = driftClock * 0.25
        let drift = SIMD2<Float>(
            amp * (0.75 * sin(k * 0.37) + 0.25 * sin(k * 0.83 + 1.0)),
            amp * (0.70 * sin(k * 0.54 + 2.1) + 0.30 * sin(k * 1.07)))

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let buffer = queue.makeCommandBuffer()
        else { return }

        let w = Float(view.drawableSize.width), h = Float(view.drawableSize.height)
        let strength = Float(params["BLOOM"])
        // The scene always lands in the offscreen pair — colour in one target,
        // the disk's own light in the other — because bloom has to key on
        // emission alone. Only the blur passes are conditional.
        guard bloom.resize(width: Int(w), height: Int(h)) else { return }
        let wantsBloom = strength > 0.001

        // Live screen content is not a loaded texture — it arrives per frame,
        // already cropped to the widget where the OS supports it. This has to
        // happen before the render encoder opens: building the mip chain is a
        // blit, and a command buffer will only have one encoder at a time.
        var texture = placeholder
        var fit = BackgroundFit()
        var hasSky = false
        if lens == .screen {
            let frame = MainActor.assumeIsolated { ScreenCapture.shared.currentFrame() }
            // Drag the widget to another monitor and the stream has to move with
            // it. Until it does, the running capture still holds the *old*
            // display, and sampling that would show a slice of the wrong screen.
            if let frame, let window = view.window, let screen = window.screen,
               screen.displayID == frame.displayID {
                texture = mipmapped(frame.texture, in: buffer) ?? frame.texture
                fit = frame.cropped
                    ? BackgroundFit()
                    : BackgroundFit.screenRect(window: window.frame, display: screen.frame)
                hasSky = true
            }
        }

        guard let sceneTarget = bloom.scenePass(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: sceneTarget)
        else { return }

        // One slot on the sky plane, two things that can occupy it: a dropped
        // file, or the pointer's own image. A drop wins — it is a deliberate
        // act, and it finishes in a couple of seconds.
        let (fallCentre, fallSize, fallAlpha, fallTear, fallTexture) = MainActor.assumeIsolated {
            () -> (SIMD2<Float>, Float, Float, Float, MTLTexture?) in
            if Faller.shared.step(shadowRadius: Float(params.shadowRadiusFraction())) {
                Impacts.shared.strike()
            }
            if Faller.shared.takeDelivery() {
                // The stream reached the disk. Where round it, in the disk's own
                // azimuth: a screen direction maps onto the plane through the
                // inclination, since the disk is a circle seen edge-on-ish and
                // its vertical extent is foreshortened by cos(incl).
                let c = Faller.shared.centre - SIMD2<Float>(0.5, 0.5)
                let roll = Float(params["DISK_ROLL"])
                let sx = c.x * cos(roll) - (-c.y) * sin(roll)
                let sy = c.x * sin(roll) + (-c.y) * cos(roll)
                let ci = max(cos(Float(params["DISK_INCL"])), 0.05)
                let alpha = atan2(sy, sx)
                Impacts.shared.deliver(angle: atan2(sin(alpha), cos(alpha) * ci),
                                       colour: Faller.shared.colour)
            }
            if let dropped = Faller.shared.texture, Faller.shared.alpha > 0.01 {
                return (Faller.shared.centre, Faller.shared.size, Faller.shared.alpha,
                        Faller.shared.tear, dropped)
            }
            if let ghost = Proximity.shared.ghostTexture {
                return (Proximity.shared.ghost, Proximity.shared.ghostSize,
                        Proximity.shared.ghostAlpha, Proximity.shared.ghostTear, ghost)
            }
            return (SIMD2<Float>(0.5, 0.5), 0, 0, 0, nil)
        }

        var u = params.uniforms(time: time, diskPhase: diskPhase,
                                width: max(w, 1), height: max(h, 1),
                                bgFit: fit, skyAlpha: hasSky ? 1 : 0,
                                flare: flare, audio: audio, drift: drift)
        // The sources work relative to the widget's centre; the hole is off
        // there by the drift, and the overlay is polar around the hole.
        let aspect = max(w, 1) / max(h, 1)
        u.fallX = (fallCentre.x - 0.5 - drift.x) * aspect
        u.fallY = (fallCentre.y - 0.5 - drift.y)
        u.fallSize = fallSize
        u.fallAlpha = fallAlpha
        u.hover = hover
        u.fallTear = fallTear
        let fed = MainActor.assumeIsolated { Impacts.shared.feed() }
        u.feedAngle = fed.angle
        u.feedStrength = fed.strength
        u.feedR = fed.colour.x
        u.feedG = fed.colour.y
        u.feedB = fed.colour.z
        u.plunge = Float(params["PLUNGE"])
        if lowPower { u.nSteps = max(u.nSteps * 0.6, 12) }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(fallTexture ?? placeholder, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        bloom.run(in: buffer, finalPass: pass, blur: wantsBloom,
                  threshold: Float(params["BLOOM_THRESHOLD"]), strength: strength)

        buffer.present(drawable)
        buffer.commit()
    }
}

/// Bright-pass, separable blur and composite, at quarter resolution.
///
/// Kept apart from the tracer because it is ordinary screen-space work — no
/// geodesics, no physics, just the observation that bright things spill.
final class BloomChain {
    struct Uniforms {
        var threshold: Float = 0
        var strength: Float = 0
        var texelX: Float = 0
        var texelY: Float = 0
        var dirX: Float = 0
        var dirY: Float = 0
        var pad0: Float = 0
        var pad1: Float = 0
    }

    private let device: MTLDevice
    private let bright: MTLRenderPipelineState
    private let blurState: MTLRenderPipelineState
    private let composite: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private var scene: MTLTexture?
    private var emission: MTLTexture?
    private var ping: MTLTexture?
    private var pong: MTLTexture?
    private var size = (w: 0, h: 0)

    /// Half-float: the blur sums many taps, and 8-bit banding shows badly in a
    /// smooth gradient over a dark background.
    static let format = MTLPixelFormat.rgba16Float

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        func pipeline(_ fragment: String, blending: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "blackholeVertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = blending ? .bgra8Unorm : Self.format
            if blending {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        bright = try pipeline("bloomBright", blending: false)
        blurState = try pipeline("bloomBlur", blending: false)
        composite = try pipeline("bloomComposite", blending: true)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else {
            throw RendererError.noSampler
        }
        self.sampler = sampler
    }

    /// Returns false if the targets could not be allocated, so the caller can
    /// fall back to drawing straight to the screen instead of dropping frames.
    func resize(width: Int, height: Int) -> Bool {
        guard width > 8, height > 8 else { return false }
        if size == (width, height), scene != nil { return true }
        func make(_ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.format, width: max(w, 1), height: max(h, 1), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let s = make(width, height),
              let e = make(width, height),
              let a = make(width / 4, height / 4),
              let b = make(width / 4, height / 4) else { return false }
        scene = s; emission = e; ping = a; pong = b
        size = (width, height)
        return true
    }

    func scenePass() -> MTLRenderPassDescriptor? {
        guard let scene, let emission else { return nil }
        let d = MTLRenderPassDescriptor()
        for (i, t) in [scene, emission].enumerated() {
            d.colorAttachments[i].texture = t
            d.colorAttachments[i].loadAction = .clear
            d.colorAttachments[i].storeAction = .store
            d.colorAttachments[i].clearColor = MTLClearColorMake(0, 0, 0, 0)
        }
        return d
    }

    func run(in buffer: MTLCommandBuffer, finalPass: MTLRenderPassDescriptor,
             blur: Bool, threshold: Float, strength: Float) {
        guard let scene, let emission, let ping, let pong else { return }

        func pass(_ target: MTLTexture?, _ descriptor: MTLRenderPassDescriptor?,
                  _ state: MTLRenderPipelineState, _ textures: [MTLTexture],
                  _ uniforms: Uniforms) {
            let d: MTLRenderPassDescriptor
            if let descriptor {
                d = descriptor
            } else {
                guard let target else { return }
                d = MTLRenderPassDescriptor()
                d.colorAttachments[0].texture = target
                d.colorAttachments[0].loadAction = .dontCare
                d.colorAttachments[0].storeAction = .store
            }
            guard let e = buffer.makeRenderCommandEncoder(descriptor: d) else { return }
            var u = uniforms
            e.setRenderPipelineState(state)
            e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            for (i, t) in textures.enumerated() { e.setFragmentTexture(t, index: i) }
            e.setFragmentSamplerState(sampler, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }

        let small = (x: 1 / Float(ping.width), y: 1 / Float(ping.height))
        let full = (x: 1 / Float(scene.width), y: 1 / Float(scene.height))

        var u = Uniforms(threshold: threshold, strength: strength,
                         texelX: small.x, texelY: small.y)
        if blur {
            // Emission only. Handing this the composed scene is what made a
            // pale wallpaper glow.
            pass(ping, nil, bright, [emission], u)
            u.dirX = 1; u.dirY = 0
            pass(pong, nil, blurState, [ping], u)
            u.dirX = 0; u.dirY = 1
            pass(ping, nil, blurState, [pong], u)
        }

        u = Uniforms(threshold: threshold, strength: blur ? strength : 0,
                     texelX: full.x, texelY: full.y)
        pass(nil, finalPass, composite, [scene, ping], u)
    }
}
