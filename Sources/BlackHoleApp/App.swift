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
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(params: Shared.params, model: Shared.model)
        } label: {
            Image(systemName: "circle.circle.fill")
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
            }
            ScreenCapture.shared.capturesAudio = Shared.model.audioReactive
                && Shared.model.lens == .screen
            Shared.model.onLensChange = { Shared.widget.lensChanged() }
            Shared.model.onPositionChange = { Shared.widget.positionModeChanged() }
            Shared.model.onSizeChange = { Shared.widget.sizeChanged() }
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

@MainActor
final class AppModel: ObservableObject {
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

    var origin: CGPoint? {
        didSet {
            guard let origin else { return }
            UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: "origin")
        }
    }

    var onLensChange: (() -> Void)?
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
        size = d.object(forKey: "size") as? Double ?? WidgetSize.medium.points
        lens = LensSource(rawValue: d.string(forKey: "lens") ?? "") ?? .screen
        audioReactive = d.bool(forKey: "audioReactive")
        launchAtLogin = LoginItem.isEnabled
        position = PanelPosition(rawValue: d.string(forKey: "position") ?? "") ?? .free
        swallowAction = SwallowAction(rawValue: d.string(forKey: "swallowAction") ?? "") ?? .animateOnly
        if let p = d.dictionary(forKey: "origin") as? [String: Double],
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
        }

        Menu("Dropped files") {
            ForEach(SwallowAction.allCases) { a in
                Button(check(model.swallowAction == a) + a.label) { model.swallowAction = a }
            }
        }

        Divider()

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
