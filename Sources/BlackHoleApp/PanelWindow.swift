import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Where the widget puts itself.
enum PanelPosition: String, CaseIterable, Identifiable {
    case free, followCursor, snapToWindow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free:         return "Stay put"
        case .followCursor: return "Follow cursor"
        case .snapToWindow: return "Snap to active window"
        }
    }
}

/// What happens to a file after the hole swallows it.
enum SwallowAction: String, CaseIterable, Identifiable {
    case animateOnly, moveToTrash

    var id: String { rawValue }

    var label: String {
        switch self {
        case .animateOnly: return "Just the animation"
        case .moveToTrash: return "Move it to the Trash"
        }
    }
}

/// The floating black hole.
///
/// The window is a square because AppKit windows are, but nothing that reaches
/// the screen is: the shader tapers its output to a soft-edged disc, and this
/// controller keeps the *click* region matched to that disc, so the corners are
/// not there at all.
@MainActor
final class PanelController {
    /// Placement is the one part of this that depends on when AppKit decides
    /// to answer, so it is the one part worth being able to read back.
    private static let log = Logger(subsystem: "dev.zghey.blackhole", category: "panel")

    /// The drawn disc is sized from the hole now, so the hit region asks the
    /// parameters rather than assuming a fixed fraction of the window.
    static func silhouetteRadius(_ params: Params) -> Double {
        params.haloRadiusFraction()
    }

    private var panel: NSPanel?
    private var content: PanelContentView?
    private var positionTimer: Timer?
    private var hitTestTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private let params: Params
    private let model: AppModel

    init(params: Params, model: AppModel) {
        self.params = params
        self.model = model
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    var isEnabled = false {
        didSet { if isEnabled != oldValue { rebuild() } }
    }

    func rebuild() {
        positionTimer?.invalidate(); positionTimer = nil
        hitTestTimer?.invalidate(); hitTestTimer = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        panel?.orderOut(nil)
        panel = nil
        content = nil

        guard isEnabled else {
            ScreenCapture.shared.stop()
            ScreenCapture.shared.setExcludedWindows([])
            return
        }

        let size = model.size
        let origin = Self.placeableOrigin(model.origin, size: size)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: CGSize(width: size, height: size)),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = NSWindow.Level.floating
        p.isOpaque = false
        p.backgroundColor = NSColor.clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false   // the content view moves it, so a drop is distinguishable
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = PanelContentView(frame: NSRect(origin: .zero, size: CGSize(width: size, height: size)))
        view.model = model
        view.controller = self
        let host = NSHostingView(rootView: RenderView(params: params, model: model))
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        // MTKView implements none of the mouse handlers, so clicks and drags
        // fall through the responder chain to PanelContentView below it.
        view.addSubview(host)

        p.contentView = view
        p.orderFrontRegardless()

        panel = p
        content = view
        Self.log.notice("panel placed at \(origin.x, privacy: .public),\(origin.y, privacy: .public) size \(size, privacy: .public) -> screen \(self.panelScreen?.displayID ?? 0, privacy: .public) (AppKit says \(p.screen?.displayID ?? 0, privacy: .public))")
        model.originDisplay = panelScreen?.displayID
        p.alphaValue = model.hidden ? 0 : 1
        syncCaptureExclusion()
        startPositionTimer()
        startHitTestTimer()
        observeScreenChanges(for: p)
        observeVisibility(for: p)
        // A widget restored hidden must not come up holding a capture stream,
        // so the capture is started by syncRunning rather than before it — an
        // unconditional lensChanged() here raced its own stop() and won.
        running = false
        syncRunning(reason: "launch")
    }

    // ------------------------------------------------------------ capture --

    /// The widget's own window must never end up in its own screen capture.
    private func syncCaptureExclusion() {
        let ids = Set([panel?.windowNumber].compactMap { $0 }.map { CGWindowID($0) })
        ScreenCapture.shared.setExcludedWindows(ids)
    }

    /// Fade rather than order out: the capture stream, the position timers and
    /// the hit region all stay exactly as they were, so unhiding is instant.
    /// Hiding used to be cosmetic: alpha 0, everything else still running. That
    /// is the wrong thing for the one moment people reach for it — sharing a
    /// screen — because the widget goes on holding a ScreenCaptureKit stream,
    /// and macOS goes on saying so in the menu bar.
    ///
    /// So hiding now really stops: the stream is torn down and the view stops
    /// drawing. The teardown waits for the fade to finish, or the lensed
    /// background would vanish a beat before the widget does.
    // ------------------------------------------------------------ parking --

    /// Everything that can stop the widget without the user asking.
    ///
    /// They all want the same thing — tear the capture down, stop drawing, stop
    /// polling — so they share one path. Only the explicit hide fades; nobody
    /// can see the others happen by definition.
    private var displaysAsleep = false
    private var screenLocked = false
    private var occluded = false

    /// Should anything be running at all?
    private var shouldRun: Bool {
        !model.hidden && !displaysAsleep && !screenLocked && !occluded
    }
    private var running = true

    /// Park or unpark to match `shouldRun`. Idempotent.
    private func syncRunning(reason: String) {
        let want = shouldRun
        guard want != running else { return }
        running = want
        if want {
            lensChanged()
            startHitTestTimer()
            Proximity.shared.setEnabled(model.noticesPointer)
        } else {
            // The hit-region poll would otherwise keep handing the window back
            // its clicks the moment the pointer crossed where the widget used
            // to be — a parked widget that still eats clicks is worse than a
            // visible one. Stopping it also parks the last 60 Hz timer.
            // Proximity goes with it, or a cursor hidden inside the hole at the
            // moment the widget parks never comes back: the render loop that
            // would have restored it is no longer running.
            hitTestTimer?.invalidate()
            hitTestTimer = nil
            Proximity.shared.setEnabled(false)
            panel?.ignoresMouseEvents = true
            ScreenCapture.shared.stop()
        }
        Self.log.notice("\(want ? "running" : "parked", privacy: .public) (\(reason, privacy: .public))")
    }

    /// Hiding used to be cosmetic: alpha 0, everything else still going. That is
    /// exactly wrong for the one moment anyone reaches for it — you hide the
    /// widget because you are about to share your screen, and it went on holding
    /// a ScreenCaptureKit stream with macOS going on saying so in the menu bar.
    func hiddenChanged() {
        guard let panel else { return }
        panel.ignoresMouseEvents = model.hidden
        if model.hidden {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fade
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                // The teardown waits for the fade, or the lensed background
                // disappears a beat before the widget does.
                MainActor.assumeIsolated { self?.syncRunning(reason: "hidden") }
            }
        } else {
            // Back before the fade, so the first frames have something to lens;
            // the capture takes about 130 ms and the fade covers it.
            syncRunning(reason: "shown")
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fade
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Displays asleep, session locked, or the widget fully covered — nobody is
    /// looking at it, so it has no business holding a capture stream or
    /// integrating geodesics. The widget floats above ordinary windows, so
    /// occlusion in practice means the screen went away rather than a window
    /// covering it; it is the cheap general net behind the two specific ones.
    private func observeVisibility(for panel: NSPanel) {
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        func on(_ centre: NotificationCenter, _ name: Notification.Name,
                _ body: @escaping @MainActor (PanelController) -> Void) {
            observers.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { body(self) } }
            })
        }
        on(ws, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true; $0.syncRunning(reason: "displays asleep") }
        on(ws, NSWorkspace.screensDidWakeNotification)  { $0.displaysAsleep = false; $0.syncRunning(reason: "displays awake") }
        on(dnc, Notification.Name("com.apple.screenIsLocked"))   { $0.screenLocked = true; $0.syncRunning(reason: "screen locked") }
        on(dnc, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false; $0.syncRunning(reason: "screen unlocked") }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel else { return }
                self.occluded = !p.occlusionState.contains(.visible)
                self.syncRunning(reason: self.occluded ? "occluded" : "visible")
            }
        })
    }

    private static let fade: TimeInterval = 0.25

    func lensChanged() {
        guard isEnabled, model.lens == .screen else {
            ScreenCapture.shared.stop()
            return
        }
        guard let screen = panelScreen else { return }
        ScreenCapture.shared.start(on: screen)
        if let panel { ScreenCapture.shared.setSourceRect(window: panel.frame, screen: screen) }
    }

    /// The screen the widget is actually on.
    ///
    /// `NSWindow.screen` is nil for a window that has not been placed yet, and
    /// falling back to `NSScreen.main` there is how the capture ended up
    /// streaming the *main* display while the widget sat on a second one — with
    /// no screen-change notification to ever correct it, because the window
    /// never changed screens. Geometry always answers.
    var panelScreen: NSScreen? {
        guard let panel else { return NSScreen.main }
        if let screen = panel.screen { return screen }
        let frame = panel.frame
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let containing = NSScreen.screens.first(where: { $0.frame.contains(centre) }) {
            return containing
        }
        return NSScreen.screens.max {
            $0.frame.intersection(frame).area < $1.frame.intersection(frame).area
        } ?? NSScreen.main
    }

    private func observeScreenChanges(for panel: NSPanel) {
        let centre = NotificationCenter.default
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didMoveNotification] {
            observers.append(centre.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let p = self.panel else { return }
                    Self.log.notice("\(name.rawValue, privacy: .public): frame \(p.frame.origin.x, privacy: .public),\(p.frame.origin.y, privacy: .public) -> screen \(self.panelScreen?.displayID ?? 0, privacy: .public)")
                    self.model.originDisplay = self.panelScreen?.displayID
                    self.lensChanged()
                }
            })
        }
        observers.append(centre.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reclampPosition()
                self?.lensChanged()
            }
        })
    }

    // ----------------------------------------------------------- geometry --

    private static func defaultOrigin(size: CGFloat) -> CGPoint {
        guard let screen = NSScreen.main else { return CGPoint(x: 200, y: 200) }
        let f = screen.visibleFrame
        return CGPoint(x: f.maxX - size - 40, y: f.maxY - size - 40)
    }

    /// A saved position can name a display that is no longer attached — unplug
    /// a monitor with the widget on it and it comes back invisible, off the
    /// edge of every screen, with no way to drag it home.
    private static func placeableOrigin(_ saved: CGPoint?, size: CGFloat) -> CGPoint {
        guard let saved else { return defaultOrigin(size: size) }
        let rect = CGRect(origin: saved, size: CGSize(width: size, height: size))
        let needed = size * size * 0.25
        let visible = NSScreen.screens.contains { $0.frame.intersection(rect).area >= needed }
        return visible ? saved : defaultOrigin(size: size)
    }

    private func reclampPosition() {
        guard let panel else { return }
        let placed = Self.placeableOrigin(panel.frame.origin, size: panel.frame.width)
        guard placed != panel.frame.origin else { return }
        panel.setFrameOrigin(placed)
        model.origin = placed
    }

    /// Nudge the widget fully onto one display.
    ///
    /// A capture covers a single screen, so the half hanging over the other one
    /// has no pixels to lens and would smear the edge of the texture across
    /// itself. Snapping on drop is cheaper than pretending to handle it.
    func settleOntoOneScreen() {
        guard let panel, let screen = panelScreen else { return }
        var frame = panel.frame
        // `frame`, not `visibleFrame`: the latter stops at the menu bar, which
        // is why the widget could not be pushed to the very top of a screen. It
        // sits below the menu bar in the window list anyway, so letting it go
        // up there costs nothing.
        let bounds = screen.frame
        guard !bounds.contains(frame) else { return }
        frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        panel.setFrame(frame, display: true)
        model.origin = frame.origin
        lensChanged()
    }

    func sizeChanged() {
        guard let panel else { return }
        let size = model.size
        guard abs(panel.frame.width - size) > 0.5 else { return }
        var frame = panel.frame
        // Grow around the centre, so resizing does not walk the widget away.
        frame.origin.x += (frame.width - size) / 2
        frame.origin.y += (frame.height - size) / 2
        frame.size = CGSize(width: size, height: size)
        panel.setFrame(frame, display: true)
        model.origin = frame.origin
        lensChanged()
    }

    // ------------------------------------------------------------ chasing --

    private func startPositionTimer() {
        guard model.position != .free else { return }
        // 60 Hz for the cursor chase (it has to look like motion, not
        // teleporting), 4 Hz is plenty for a window that only moves when dragged.
        let interval = model.position == .followCursor ? 1.0 / 60 : 0.25
        positionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepPosition() }
        }
    }

    private func stepPosition() {
        guard let panel else { return }
        switch model.position {
        case .free:
            return
        case .followCursor:
            let mouse = NSEvent.mouseLocation
            let size = panel.frame.size
            let target = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
            // Ease rather than snap: a widget glued to the pointer is
            // distracting, one that trails it reads as mass.
            let cur = panel.frame.origin
            panel.setFrameOrigin(CGPoint(x: cur.x + (target.x - cur.x) * 0.12,
                                         y: cur.y + (target.y - cur.y) * 0.12))
        case .snapToWindow:
            guard let rect = AccessibilityWindow.frontmostFrame() else { return }
            let size = panel.frame.size
            let target = CGPoint(x: rect.maxX - size.width * 0.5, y: rect.maxY - size.height * 0.5)
            let cur = panel.frame.origin
            panel.setFrameOrigin(CGPoint(x: cur.x + (target.x - cur.x) * 0.35,
                                         y: cur.y + (target.y - cur.y) * 0.35))
        }
    }

    func positionModeChanged() {
        positionTimer?.invalidate()
        positionTimer = nil
        startPositionTimer()
        updateHitRegion()
    }

    // ---------------------------------------------------------- hit region --

    /// An AppKit window's click area is all-or-nothing, but what the widget
    /// draws is a disc with a soft edge. Polling the pointer and flipping
    /// `ignoresMouseEvents` gives the window the shape of its own contents:
    /// inside the disc it is something you can drag and drop onto, outside it
    /// the corners are not there and the click lands on whatever is underneath.
    ///
    /// 60 Hz because the alternative is a click arriving before the window has
    /// noticed the pointer; the work is one distance comparison.
    ///
    /// `MainActor.assumeIsolated`, not `Task { @MainActor in }`. The timer is
    /// scheduled from the main actor so it fires on the main run loop already —
    /// wrapping the body in a Task allocated one and hopped the executor sixty
    /// times a second to arrive on the thread it was on, which cost more than
    /// the work it was guarding. Same reasoning for the position timer.
    private func startHitTestTimer() {
        hitTestTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHitRegion() }
        }
    }

    private func updateHitRegion() {
        guard let panel else { return }
        let busy = content?.isInteracting ?? false
        // Chasing the pointer means sitting under it permanently. Staying
        // interactive there would block every click on the desktop, so that
        // mode is decoration only — drops need "Stay put".
        if model.position == .followCursor && !busy {
            panel.ignoresMouseEvents = true
            return
        }
        let frame = panel.frame
        let radius = frame.height * Self.silhouetteRadius(params)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        Proximity.shared.centre = centre
        Proximity.shared.radius = radius
        let mouse = NSEvent.mouseLocation
        let inside = hypot(mouse.x - centre.x, mouse.y - centre.y) <= radius
        panel.ignoresMouseEvents = !(inside || busy)
    }
}

// ------------------------------------------------------------ content view --

/// Everything the Metal view cannot do: move the widget, resize it by its rim,
/// and swallow files dropped onto it.
final class PanelContentView: NSView {
    weak var model: AppModel?
    weak var controller: PanelController?

    /// True while a drag or a drop is in flight, so the hit-region poller
    /// cannot make the window click-through mid-gesture.
    private(set) var isInteracting = false

    private var dragging = false
    private var grabPoint: NSPoint = .zero
    private var grabOrigin: NSPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        // Files are the obvious thing to feed it, but a selection of text, a
        // link out of the address bar or an image off a web page are all just
        // as droppable — and refusing them makes the widget feel inert.
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        // A hint that the rim does something: the pointer changes as it crosses
        // into the resize band.
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    // ---- moving ----

    override func mouseDown(with event: NSEvent) {
        guard model?.position == .free else { return }
        dragging = true
        isInteracting = true
        grabPoint = NSEvent.mouseLocation
        grabOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let window else { return }
        let now = NSEvent.mouseLocation
        window.setFrameOrigin(CGPoint(x: grabOrigin.x + (now.x - grabPoint.x),
                                      y: grabOrigin.y + (now.y - grabPoint.y)))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragging = false; isInteracting = false }
        if event.clickCount == 2 {
            Shared.advanced.show()
            return
        }
        guard dragging else { return }
        if let window, let model { model.origin = window.frame.origin }
        controller?.settleOntoOneScreen()
    }

    // ---- swallowing files ----

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !Morsel.read(from: sender.draggingPasteboard).isEmpty else { return [] }
        isInteracting = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isInteracting = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { isInteracting = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isInteracting = false
        let morsels = Morsel.read(from: sender.draggingPasteboard)
        guard !morsels.isEmpty else { return false }
        let dropPoint = convert(sender.draggingLocation, from: nil)
        for (index, morsel) in morsels.enumerated() {
            swallow(morsel, from: dropPoint, delay: Double(index) * 0.12)
        }
        return true
    }

    /// Hand it to the shader, which paints it onto the sky plane where the
    /// geodesics can bend it. The animation that used to live here — a layer
    /// spiralling in over the render — could not be lensed, which is exactly
    /// why it read as an icon animating over a picture of a black hole.
    private func swallow(_ morsel: Morsel, from start: NSPoint, delay: TimeInterval) {
        let uv = SIMD2<Float>(Float(start.x / max(bounds.width, 1)),
                              Float(1 - start.y / max(bounds.height, 1)))
        let image = morsel.image
        let action = model?.swallowAction ?? .animateOnly
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Faller.shared.swallow(image, from: uv)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + Faller.duration) {
            // The destructive step happens only after it is gone, only when
            // explicitly enabled, and only for things that exist on disk — the
            // default eats nothing.
            if action == .moveToTrash, case .file(let url) = morsel.kind {
                NSWorkspace.shared.recycle([url])
            }
        }
    }
}

// ------------------------------------------------------ accessibility peek --

/// Frame of the frontmost app's focused window, for snap-to-window.
///
/// The one feature that needs the Accessibility permission; without it this
/// returns nothing and the widget holds still rather than failing loudly.
enum AccessibilityWindow {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func frontmostFrame() -> CGRect? {
        guard isTrusted,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString,
                                            &windowRef) == .success,
              let window = windowRef, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        let axWindow = window as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        // AX reports top-left origin coordinates; NSWindow frames are bottom-left.
        guard let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: origin.x, y: primary.frame.maxY - origin.y - size.height,
                      width: size.width, height: size.height)
    }
}

extension CGRect {
    /// Zero for a null or empty intersection, so overlap comparisons stay well
    /// defined when the widget straddles two displays.
    fileprivate var area: CGFloat { (isNull || isEmpty) ? 0 : width * height }
}

// ------------------------------------------------------------------ morsels --

/// Something the hole can swallow, and the picture of it that falls in.
struct Morsel {
    enum Kind {
        case file(URL)
        case link(URL)
        case text(String)
        case image
    }

    let kind: Kind
    let image: NSImage

    /// Everything droppable on the pasteboard, richest interpretation first.
    /// Order matters: a file drag also carries a URL and often a string, and
    /// swallowing the same thing three times would look absurd.
    static func read(from pasteboard: NSPasteboard) -> [Morsel] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { Morsel(kind: .file($0), image: NSWorkspace.shared.icon(forFile: $0.path)) }
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           !images.isEmpty {
            return images.map { Morsel(kind: .image, image: $0) }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            return urls.map { Morsel(kind: .link($0), image: linkImage($0)) }
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return [Morsel(kind: .text(text), image: textImage(text))]
        }
        return []
    }

    /// The same image pushed far down the spectrum, for cross-fading during
    /// the infall. Multiplying by a deep red is a crude stand-in for a
    /// blackbody shift, but at 64 points nobody is checking the spectrum.
    static func redshifted(_ image: NSImage) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSColor(calibratedRed: 0.85, green: 0.10, blue: 0.05, alpha: 1).set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    private static func linkImage(_ url: URL) -> NSImage {
        NSImage(systemSymbolName: "link", accessibilityDescription: url.absoluteString)
            ?? NSImage(size: NSSize(width: 64, height: 64))
    }

    /// A scrap of the text itself, so you can see what went in.
    private static func textImage(_ text: String) -> NSImage {
        let snippet = String(text.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: snippet, attributes: attrs)
        let bounds = string.boundingRect(with: NSSize(width: 220, height: 60),
                                         options: [.usesLineFragmentOrigin])
        let size = NSSize(width: max(bounds.width, 24) + 16, height: max(bounds.height, 16) + 12)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.08, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                     xRadius: 6, yRadius: 6).fill()
        string.draw(with: NSRect(x: 8, y: 6, width: size.width - 16, height: size.height - 12),
                    options: [.usesLineFragmentOrigin])
        image.unlockFocus()
        return image
    }
}
