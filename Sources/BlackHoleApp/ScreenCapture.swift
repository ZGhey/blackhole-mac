import AppKit
import CoreVideo
import Metal
import os
import ScreenCaptureKit

/// Live screen content as an MTLTexture, for the panel to lens.
///
/// This is what makes the hole bend *your windows* instead of a picture of
/// them: ScreenCaptureKit streams the display the panel sits on, the shader
/// samples the sub-rect the panel covers, and the panel composites back over
/// the real thing with alpha. The panel's own windows are excluded from the
/// filter — capturing them would feed the render back into itself.
///
/// Needs the Screen Recording permission. Until it is granted the stream
/// simply never starts and `texture` stays nil, which the renderer shows as a
/// transparent panel rather than an error.
@MainActor
final class ScreenCapture: NSObject {
    static let shared = ScreenCapture()

    /// The capture is invisible when it works and baffling when it does not
    /// (wrong monitor, denied permission, a stream that quietly stopped), and
    /// stderr is discarded for a bundled app — so it reports to the unified log.
    /// `log stream --predicate 'subsystem == "dev.s13k.blackhole-app"'`
    private static let log = Logger(subsystem: "dev.s13k.blackhole-app", category: "capture")

    /// Latest captured frame. Written on the stream's queue, read on the
    /// render thread — both are the main thread here, since the stream output
    /// queue is main and MTKView draws on main.
    /// One captured frame plus what it means. `cropped` says the stream is
    /// already limited to the widget's rect, so the shader samples it 1:1
    /// instead of indexing into a whole display.
    struct Frame {
        let texture: MTLTexture
        let displayID: CGDirectDisplayID
        let cropped: Bool
    }

    private(set) var texture: MTLTexture?
    private(set) var isRunning = false
    /// Smoothed system-audio envelope, 0…1. The stream already exists for the
    /// picture, so the sound is nearly free — one more output type.
    private(set) var audioLevel: Float = 0
    /// Coalesces crop re-aims while the widget is being dragged.
    private var reaimTask: Task<Void, Never>?
    private static let reaimInterval: Double = 0.1
    /// Arrival rate of screen frames, for telling "the capture stopped" apart
    /// from "nothing behind the widget moved".
    private var framesSinceTick = 0
    private var lastTick = CACurrentMediaTime()
    /// Whether to ask for audio at all. Changing it restarts the stream, since
    /// SCStreamConfiguration is fixed once a stream is created.
    var capturesAudio = false {
        didSet {
            guard capturesAudio != oldValue else { return }
            audioLevel = 0
            if isRunning { pump(force: true) }
        }
    }
    private(set) var failure: String?

    private var stream: SCStream?
    private var textureCache: CVMetalTextureCache?
    private var device: MTLDevice?
    private var excludedWindowIDs: Set<CGWindowID> = []
    /// The display the panel is on *now* — updated the moment it moves.
    private var desiredDisplayID: CGDirectDisplayID?
    /// The display the running stream is actually capturing. The two differ
    /// while a restart is in flight, and the renderer must not sample one
    /// display's pixels through another display's rect.
    private(set) var activeDisplayID: CGDirectDisplayID?
    private var restarting = false
    /// The widget's rect, in the capture's display coordinates. Streaming only
    /// this instead of the whole display is a large saving: a 350 pt widget on
    /// a 2940x1912 screen is under 2% of the pixels.
    private var sourceRect: CGRect?
    private var croppedStream = false
    private var retryTask: Task<Void, Never>?
    private var loggedFailure: String?

    /// How long to wait before trying again after a failed start. Without this
    /// a denied permission turns into a tight retry loop that hammers TCC and
    /// floods the log — which is exactly what it did before the backoff existed.
    private static let retryDelay: TimeInterval = 5

    func configure(device: MTLDevice) {
        guard self.device == nil else { return }
        self.device = device
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// Windows that must never appear in the capture — the panels themselves.
    /// Changing the set restarts the stream, since SCContentFilter is fixed
    /// once a stream is created.
    func setExcludedWindows(_ ids: Set<CGWindowID>) {
        guard ids != excludedWindowIDs else { return }
        excludedWindowIDs = ids
        if isRunning { restart() }
    }

    /// Point the capture at whichever display the panel currently occupies.
    /// Safe to call as often as you like — it no-ops unless something changed.
    func currentFrame() -> Frame? {
        guard let texture, let activeDisplayID, isRunning else { return nil }
        return Frame(texture: texture, displayID: activeDisplayID, cropped: croppedStream)
    }

    /// Follow the widget: which display it is on, and where on it.
    ///
    /// macOS 14 can re-aim a running stream, so a drag inside one display is a
    /// configuration update rather than a restart. On 13 the crop is fixed at
    /// stream creation, so it falls back to capturing the whole display and
    /// letting the shader index into it.
    func setSourceRect(window: NSRect, screen: NSScreen) {
        guard let displayID = screen.displayID else { return }
        // ScreenCaptureKit wants display-local, top-left-origin points.
        let rect = CGRect(x: window.minX - screen.frame.minX,
                          y: screen.frame.maxY - window.maxY,
                          width: window.width, height: window.height)
        let changed = sourceRect.map { abs($0.minX - rect.minX) > 0.5 || abs($0.minY - rect.minY) > 0.5
                                       || abs($0.width - rect.width) > 0.5 } ?? true
        sourceRect = rect
        guard changed, isRunning, activeDisplayID == displayID else { return }
        scheduleReaim(scale: screen.backingScaleFactor)
    }

    /// Re-aim the crop at 10 Hz, not at every mouse-move.
    ///
    /// `setSourceRect` runs off NSWindowDidMove, so dragging the widget fired
    /// one `updateConfiguration` per pixel of travel — measured at one every
    /// ~17 ms, which is a 60 Hz round-trip to ScreenCaptureKit and ReplayKit
    /// for a crop that has moved by one point. Coalescing keeps the last
    /// position rather than the first, so the trailing call always lands on
    /// where the drag actually ended.
    private func scheduleReaim(scale: CGFloat) {
        guard reaimTask == nil else { return }   // in flight; it will read the latest rect
        reaimTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.reaimInterval * 1_000_000_000))
            self.reaimTask = nil
            guard self.croppedStream, let stream = self.stream, let rect = self.sourceRect,
                  #available(macOS 14.0, *)
            else { return }
            try? await stream.updateConfiguration(self.configuration(for: rect, scale: scale))
        }
    }

    func start(on screen: NSScreen?) {
        guard let screen, let displayID = screen.displayID else {
            Self.log.error("start: no screen resolved")
            return
        }
        if desiredDisplayID != displayID {
            Self.log.notice("target display -> \(displayID, privacy: .public)")
            // A deliberate move deserves an immediate attempt, not the tail of
            // a backoff from the display we just left.
            retryTask?.cancel()
            retryTask = nil
            loggedFailure = nil
        }
        desiredDisplayID = displayID
        pump()
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        desiredDisplayID = nil
        activeDisplayID = nil
        let old = stream
        stream = nil
        isRunning = false
        texture = nil
        audioLevel = 0
        Task { try? await old?.stopCapture() }
    }

    /// Drives the stream toward `desiredDisplayID`. Restarts are async, and the
    /// panel can be dragged onto a third display while one is still starting,
    /// so this re-checks once the in-flight attempt settles instead of dropping
    /// the newer request.
    private func pump(force: Bool = false) {
        guard !restarting, let want = desiredDisplayID else { return }
        if !force, isRunning, activeDisplayID == want { return }
        restarting = true
        let old = stream
        stream = nil
        isRunning = false
        texture = nil
        activeDisplayID = nil
        Task { @MainActor in
            try? await old?.stopCapture()
            await self.begin(displayID: want)
            self.restarting = false
            if self.isRunning {
                self.pump()                          // the target may have moved mid-start
            } else {
                self.scheduleRetry()                 // denied or transient — back off
            }
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.pump()
        }
    }

    /// Report a failure once per distinct message instead of once per attempt.
    private func note(failure message: String) {
        self.failure = message
        guard loggedFailure != message else { return }
        loggedFailure = message
        Self.log.error("\(message, privacy: .public)")
    }

    /// Forget the permission decision and ask again, which is the only way to
    /// get the system prompt back after a denial or after a rebuild changed the
    /// ad-hoc signature TCC keyed the grant to.
    func resetPermissionAndRetry() {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.s13k.blackhole-app"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", bundleID]
        try? task.run()
        task.waitUntilExit()
        loggedFailure = nil
        failure = nil
        retryTask?.cancel()
        retryTask = nil
        pump()
    }

    private func restart() { pump() }

    private func begin(displayID: CGDirectDisplayID) async {
        do {
            // excludingDesktopWindows:false keeps the wallpaper and desktop
            // icons in frame — they are exactly the things worth lensing.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                note(failure: "display \(displayID) is not in the shareable content list")
                return
            }
            let ours = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
            // Starting without our own window in the exclusion list would feed
            // the render straight back into itself — an infinite mirror. A
            // freshly ordered-in panel can take a beat to show up in the
            // shareable content, so wait and try again rather than capture it.
            if !excludedWindowIDs.isEmpty && ours.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let retry = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                let retryOurs = retry.windows.filter { excludedWindowIDs.contains($0.windowID) }
                guard !retryOurs.isEmpty else {
                    note(failure: "could not identify the widget's own window; refusing to capture (it would mirror itself)")
                    return
                }
                await begin(displayID: displayID, display: display, ours: retryOurs)
                return
            }
            await begin(displayID: displayID, display: display, ours: ours)
        } catch {
            self.isRunning = false
            note(failure: Self.describe(error))
        }
    }

    private func begin(displayID: CGDirectDisplayID, display: SCDisplay, ours: [SCWindow]) async {
        do {
            let filter = SCContentFilter(display: display, excludingWindows: ours)

            let scale = NSScreen.screens.first { $0.displayID == displayID }?.backingScaleFactor ?? 2
            let config: SCStreamConfiguration
            if #available(macOS 14.0, *), let rect = sourceRect {
                config = configuration(for: rect, scale: scale)
                croppedStream = true
            } else {
                config = baseConfiguration()
                config.width = Int(CGFloat(display.width) * scale)
                config.height = Int(CGFloat(display.height) * scale)
                croppedStream = false
            }

            config.capturesAudio = capturesAudio
            // Nothing here makes noise, but excluding ourselves is free
            // insurance against ever feeding the meter its own output.
            config.excludesCurrentProcessAudio = true

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen,
                                       sampleHandlerQueue: DispatchQueue.main)
            if capturesAudio {
                try stream.addStreamOutput(self, type: .audio,
                                           sampleHandlerQueue: DispatchQueue.main)
            }
            try await stream.startCapture()
            self.stream = stream
            self.isRunning = true
            self.activeDisplayID = displayID
            self.failure = nil
            self.loggedFailure = nil
            Self.log.notice("streaming display \(displayID, privacy: .public) at \(config.width, privacy: .public)x\(config.height, privacy: .public), excluding \(ours.count, privacy: .public) own window(s)")
        } catch {
            self.isRunning = false
            note(failure: Self.describe(error))
        }
    }

    private func baseConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        // The widget is not part of the capture, so a cursor over it would be
        // lensed into the shot — and the real cursor is drawn on top anyway.
        config.showsCursor = false
        config.scalesToFit = false
        return config
    }

    @available(macOS 14.0, *)
    private func configuration(for rect: CGRect, scale: CGFloat) -> SCStreamConfiguration {
        let config = baseConfiguration()
        config.sourceRect = rect
        config.width = max(Int(rect.width * scale), 2)
        config.height = max(Int(rect.height * scale), 2)
        return config
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        // TCC denial is the overwhelmingly likely failure, and the raw message
        // ("The user declined…") does not say where to fix it.
        if ns.domain == SCStreamError.errorDomain,
           ns.code == SCStreamError.userDeclined.rawValue {
            return "Screen Recording permission denied. Grant it in System Settings ▸ Privacy & Security ▸ Screen Recording, then re-enable panel lensing."
        }
        return ns.localizedDescription
    }
}

extension ScreenCapture: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.isRunning = false
            self.note(failure: Self.describe(error))
            self.scheduleRetry()
        }
    }
}

extension ScreenCapture: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        if type == .audio {
            let rms = Self.rms(of: sampleBuffer)
            MainActor.assumeIsolated { self.ingestAudio(rms) }
            return
        }
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        MainActor.assumeIsolated {
            self.ingest(pixelBuffer)
        }
    }
}

extension ScreenCapture {
    /// Root-mean-square of one audio buffer, in 0…1.
    fileprivate nonisolated static func rms(of sampleBuffer: CMSampleBuffer) -> Float {
        var total: Float = 0
        var count = 0
        try? sampleBuffer.withAudioBufferList { list, _ in
            for buffer in list {
                guard let data = buffer.mData else { continue }
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: n)
                for i in 0..<n { total += samples[i] * samples[i] }
                count += n
            }
        }
        guard count > 0 else { return 0 }
        return (total / Float(count)).squareRoot()
    }

    fileprivate func ingestAudio(_ rms: Float) {
        // Music sits low in linear amplitude; a cube root spreads the usable
        // range over the dial instead of leaving it pinned near zero.
        let shaped = min(pow(rms * 6.0, 1.0 / 3.0), 1.0)
        // Fast attack so a beat lands on the beat, slow release so the disk
        // glides back down instead of strobing between samples.
        let k: Float = shaped > audioLevel ? 0.55 : 0.10
        audioLevel += (shaped - audioLevel) * k
    }

    /// ScreenCaptureKit only sends a frame when the captured region actually
    /// changed, so "the lensed background froze" and "nothing behind the widget
    /// moved" look identical from the outside. Counting arrivals is the only
    /// way to tell them apart after the fact.
    fileprivate func ingest(_ pixelBuffer: CVPixelBuffer) {
        framesSinceTick += 1
        let now = CACurrentMediaTime()
        if now - lastTick >= 5 {
            // Only worth saying when it is *not* delivering. Measured on a
            // running widget it holds 29.5 fps indefinitely — it does not go
            // idle when the screen is still, so a frozen lensed background is
            // never this stream's doing and the search should go elsewhere.
            if framesSinceTick == 0 {
                Self.log.notice("no screen frames for \(now - self.lastTick, format: .fixed(precision: 1), privacy: .public)s")
            }
            framesSinceTick = 0
            lastTick = now
        }
        guard let cache = textureCache else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let metalTexture = CVMetalTextureGetTexture(cvTexture) else { return }
        texture = metalTexture
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
