import AppKit
import SwiftUI

/// The app is one floating widget and a menu-bar icon. A shared state graph is
/// simpler than threading @StateObject through an NSApplicationDelegate that
/// also has to build plain AppKit windows.
@MainActor
enum Shared {
    static let params = Params()
    static let model = AppModel()
    static let widget = PanelController(params: params, model: model)
    static let advanced = AdvancedWindow()
}

@main
struct BlackHoleApp: App {
    /// The menu-bar glyph, rendered from the same shader as everything else
    /// (see `make-icon.sh`). A template image: only its alpha is used, and the
    /// system paints it to match the menu bar, so it follows light and dark
    /// without two assets. Shipped at 36 px and declared 18 pt, which is the
    /// cheapest way to be crisp on both 1x and 2x.
    static let menuIcon: NSImage = {
        guard let url = Bundle.module.url(forResource: "MenuIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return NSImage(systemSymbolName: "circle.circle.fill", accessibilityDescription: nil)! }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(params: Shared.params, model: Shared.model)
        } label: {
            Image(nsImage: Self.menuIcon)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // No Dock icon, no menu of its own — the widget and the status item
            // are the whole interface.
            NSApp.setActivationPolicy(.accessory)
            if let device = MTLCreateSystemDefaultDevice() {
                ScreenCapture.shared.configure(device: device)
                Faller.shared.configure(device: device)
                Proximity.shared.configure(device: device)
            }
            ScreenCapture.shared.capturesAudio = Shared.model.audioReactive
                && Shared.model.lens == .screen
            Shared.model.onLensChange = { Shared.widget.lensChanged() }
            Shared.model.onPositionChange = { Shared.widget.positionModeChanged() }
            Shared.model.onSizeChange = { Shared.widget.sizeChanged() }
            Shared.model.onHiddenChange = { Shared.widget.hiddenChanged() }
            HotKey.install { Shared.model.hidden.toggle() }
            Proximity.shared.setEnabled(Shared.model.noticesPointer)
            Shared.widget.isEnabled = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // closing the Advanced window must not kill the widget
    }
}

// -------------------------------------------------------------- app state --

/// Three sizes cover it.
enum WidgetSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var label: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }
    var points: Double {
        switch self {
        case .small:  return 260
        case .medium: return 420
        case .large:  return 640
        }
    }

    /// Which preset the current size is nearest, for the menu's check mark —
    /// a size stored before the presets changed still marks something.
    static func nearest(to points: Double) -> WidgetSize {
        allCases.min { abs($0.points - points) < abs($1.points - points) } ?? .medium
    }
}

/// How often to redraw. Not a quality dial — the geodesics are the same either
/// way — but the widget is the kind of thing that runs all day, so what it
/// costs while you are not looking at it is a fair question to let you answer.
enum FrameRate: Int, CaseIterable, Identifiable {
    case fps60 = 60, fps30 = 30, fps15 = 15

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .fps60: return "60 fps"
        case .fps30: return "30 fps"
        case .fps15: return "15 fps"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var frameRate: FrameRate {
        didSet { UserDefaults.standard.set(frameRate.rawValue, forKey: "frameRate") }
    }
    @Published var size: Double {
        didSet {
            UserDefaults.standard.set(size, forKey: "size")
            onSizeChange?()
        }
    }
    @Published var lens: LensSource {
        didSet {
            UserDefaults.standard.set(lens.rawValue, forKey: "lens")
            ScreenCapture.shared.capturesAudio = audioReactive && lens == .screen
            onLensChange?()
        }
    }
    @Published var position: PanelPosition {
        didSet {
            UserDefaults.standard.set(position.rawValue, forKey: "position")
            if position == .snapToWindow && !AccessibilityWindow.isTrusted {
                AccessibilityWindow.requestPermission()
            }
            onPositionChange?()
        }
    }
    @Published var swallowAction: SwallowAction {
        didSet { UserDefaults.standard.set(swallowAction.rawValue, forKey: "swallowAction") }
    }
    /// Swallow the pointer's image when it wanders in.
    @Published var noticesPointer: Bool {
        didSet {
            UserDefaults.standard.set(noticesPointer, forKey: "noticesPointer")
            Proximity.shared.setEnabled(noticesPointer)
        }
    }
    /// Pulse the disk with system audio. Rides the screen-capture stream, so it
    /// needs the live-screen lens — there is no stream to listen through
    /// otherwise.
    @Published var audioReactive: Bool {
        didSet {
            UserDefaults.standard.set(audioReactive, forKey: "audioReactive")
            ScreenCapture.shared.capturesAudio = audioReactive && lens == .screen
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LoginItem.isEnabled else { return }
            if !LoginItem.set(launchAtLogin) { launchAtLogin = LoginItem.isEnabled }
        }
    }
    @Published var rendererError: String?
    /// Out of the way for a moment, without quitting and losing the position.
    /// Persisted: hiding it and quitting only to have it come back on the next
    /// launch is not "hidden", it is a joke with a delay on it.
    @Published var hidden: Bool {
        didSet {
            UserDefaults.standard.set(hidden, forKey: "hidden")
            onHiddenChange?()
        }
    }

    /// Positions are kept per display. A widget parked in the corner of a
    /// laptop screen has no business landing in the middle of a 5K one when you
    /// dock, and the reverse leaves it off the edge entirely.
    var origin: CGPoint? {
        didSet {
            guard let origin, let key = originKey else { return }
            UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: key)
        }
    }
    /// Which display the stored position belongs to; set by PanelController.
    var originDisplay: CGDirectDisplayID? {
        didSet {
            if let originDisplay {
                UserDefaults.standard.set(Int(originDisplay), forKey: "lastDisplay")
            }
            guard originDisplay != oldValue, let key = originKey,
                  let p = UserDefaults.standard.dictionary(forKey: key) as? [String: Double],
                  let x = p["x"], let y = p["y"] else { return }
            origin = CGPoint(x: x, y: y)
        }
    }
    private var originKey: String? {
        originDisplay.map { "origin-\($0)" }
    }

    var onLensChange: (() -> Void)?
    var onHiddenChange: (() -> Void)?
    var onPositionChange: (() -> Void)?
    var onSizeChange: (() -> Void)?

    /// nil when the live-screen lens is working or not in use.
    var captureStatus: String? {
        guard lens == .screen else { return nil }
        if let failure = ScreenCapture.shared.failure { return failure }
        return ScreenCapture.shared.isRunning ? nil : "starting the screen capture…"
    }

    var captureDenied: Bool {
        ScreenCapture.shared.failure?.contains("Screen Recording") ?? false
    }

    init() {
        let d = UserDefaults.standard
        frameRate = FrameRate(rawValue: d.object(forKey: "frameRate") as? Int ?? 0) ?? .fps60
        hidden = d.bool(forKey: "hidden")
        size = d.object(forKey: "size") as? Double ?? WidgetSize.medium.points
        lens = LensSource(rawValue: d.string(forKey: "lens") ?? "") ?? .screen
        audioReactive = d.bool(forKey: "audioReactive")
        launchAtLogin = LoginItem.isEnabled
        position = PanelPosition(rawValue: d.string(forKey: "position") ?? "") ?? .free
        swallowAction = SwallowAction(rawValue: d.string(forKey: "swallowAction") ?? "") ?? .animateOnly
        noticesPointer = d.object(forKey: "noticesPointer") as? Bool ?? true
        // The display the widget was last on, not whichever one happens to be
        // main at launch. Reading main's slot means a widget parked on a second
        // screen comes back on the first one after every restart — and then the
        // capture has to stop and start again on the right display as soon as
        // it is dragged home.
        let last = (d.object(forKey: "lastDisplay") as? Int).map { CGDirectDisplayID($0) }
        let attached = Set(NSScreen.screens.compactMap(\.displayID))
        let preferred = last.flatMap { attached.contains($0) ? $0 : nil } ?? NSScreen.main?.displayID
        if let preferred,
           let p = d.dictionary(forKey: "origin-\(preferred)") as? [String: Double],
           let x = p["x"], let y = p["y"] {
            origin = CGPoint(x: x, y: y)
        }
    }
}

// --------------------------------------------------------------- menu bar --

struct MenuContent: View {
    @ObservedObject var params: Params
    @ObservedObject var model: AppModel

    var body: some View {
        if let status = model.captureStatus {
            Text(status)
            if model.captureDenied {
                Button("Ask for Screen Recording again") {
                    ScreenCapture.shared.resetPermissionAndRetry()
                }
                Button("Open Privacy Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Divider()
        }

        Menu("Size") {
            ForEach(WidgetSize.allCases) { size in
                Button(check(WidgetSize.nearest(to: model.size) == size) + size.label) {
                    model.size = size.points
                }
            }
        }

        Menu("Style") {
            ForEach(Specs.styles, id: \.0) { name, _ in
                Button(check(params.styleName == name) + name) { params.apply(style: name) }
            }
            if !params.customStyleNames.isEmpty {
                Divider()
                ForEach(params.customStyleNames, id: \.self) { name in
                    Button(check(params.styleName == name) + name) { params.apply(style: name) }
                }
            }
            Divider()
            Button("Save current as…") { StylePrompt.saveCurrent(into: params) }
            if params.customStyles[params.styleName] != nil {
                Button("Delete “\(params.styleName)”") {
                    params.deleteStyle(named: params.styleName)
                }
            }
        }

        Menu("Lens") {
            ForEach(LensSource.allCases) { source in
                Button(check(model.lens == source) + source.label) { model.lens = source }
            }
            Divider()
            Button(check(model.audioReactive) + "Pulse with audio") {
                model.audioReactive.toggle()
            }
            if model.audioReactive && model.lens != .screen {
                Text("needs the live-screen lens")
            }
        }

        Menu("Position") {
            ForEach(PanelPosition.allCases) { p in
                Button(check(model.position == p) + p.label) { model.position = p }
            }
            if model.position == .free {
                Divider()
                Button("Snap to top") { Shared.widget.snapToEdge(.maxY) }
                Button("Snap to bottom") { Shared.widget.snapToEdge(.minY) }
                Button("Snap to left") { Shared.widget.snapToEdge(.minX) }
                Button("Snap to right") { Shared.widget.snapToEdge(.maxX) }
            }
        }

        Menu("Frame rate") {
            ForEach(FrameRate.allCases) { r in
                Button(check(model.frameRate == r) + r.label) { model.frameRate = r }
            }
        }

        Button(check(model.noticesPointer) + "Swallow the pointer") {
            model.noticesPointer.toggle()
        }

        Menu("Dropped files") {
            ForEach(SwallowAction.allCases) { a in
                Button(check(model.swallowAction == a) + a.label) { model.swallowAction = a }
            }
        }

        Divider()

        Button(model.hidden ? "Show (⌥⌘B)" : "Hide (⌥⌘B)") { model.hidden.toggle() }
        Button(check(model.launchAtLogin) + "Launch at login") {
            model.launchAtLogin.toggle()
        }
        Button("Advanced…") { Shared.advanced.show() }
        Button("Quit Black Hole") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    /// SwiftUI menus in a MenuBarExtra do not render a selection state on
    /// Buttons, so the current choice is marked in the title itself.
    private func check(_ on: Bool) -> String { on ? "✓ " : "   " }
}

// ------------------------------------------------------- advanced window --

/// Every tunable, for when the styles are not enough. Deliberately behind a
/// menu item: the widget should need nothing but Size and Style.
@MainActor
final class AdvancedWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            w.title = "Black Hole — Advanced"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(
                rootView: AdvancedPanel(params: Shared.params, model: Shared.model))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}


// -------------------------------------------------------------- style save --

/// Asking for a name. A menu-bar app has no window to hang a sheet on, so this
/// is a plain modal alert — the one moment the app is allowed to interrupt.
@MainActor
enum StylePrompt {
    static func saveCurrent(into params: Params) {
        let alert = NSAlert()
        alert.messageText = "Save this look"
        alert.informativeText = "Every slider as it stands now, under a name of your choosing."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = params.customStyles[params.styleName] != nil
            ? params.styleName : "\(params.styleName) copy"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            params.saveCurrentStyle(named: field.stringValue)
        }
    }
}
