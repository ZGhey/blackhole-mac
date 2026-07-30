import BlackHoleCore
import AppKit
import SwiftUI

/// The app is one floating widget and a menu-bar icon. A shared state graph is
/// simpler than threading @StateObject through an NSApplicationDelegate that
/// also has to build plain AppKit windows.
@MainActor
enum Shared {
    /// Before either of the two things that read UserDefaults is built. Static
    /// lets are lazy and SwiftUI may reach `params` before the delegate runs,
    /// so the ordering is expressed here rather than hoped for.
    private static let migrated: Void = LegacyDefaults.migrateIfNeeded()

    static let params: Params = { _ = migrated; return Params() }()
    static let model: AppModel = { _ = migrated; return AppModel() }()
    static let widget = PanelController(params: params, model: model)
    static let cycler = StyleCycler(params: params)
    static let advanced = AdvancedWindow()
    static let updater = Updater()
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

    /// The same glyph with a Trash badge, for while dropped files are really
    /// being thrown away.
    ///
    /// Composed rather than drawn: there is no icon art in this repo and there
    /// should not be — the hole in the menu bar is the app's own render (see
    /// `make-icon.sh`), and a second hand-made asset would be a second thing to
    /// keep in step with it. The badge is punched out of the glyph with a clear
    /// ring first, or a dark symbol on a dark hole is a smudge; both stay
    /// template, so the system still tints the pair for light and dark.
    static let menuIconArmed: NSImage = {
        // 0.44 of the glyph, measured rather than guessed: rendered at 1x beside
        // the plain one, anything above about half swallows the hole and the
        // status item stops reading as this app at all. At the retina 36 px the
        // badge is legibly a bin; at 1x it is at least unmistakably *different*,
        // which with the menu's own check mark is enough.
        let side: CGFloat = 18
        let badge = side * 0.44
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            menuIcon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            let box = NSRect(x: side - badge, y: 0, width: badge, height: badge)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: box.insetBy(dx: -1.0, dy: -1.0)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let config = NSImage.SymbolConfiguration(pointSize: badge, weight: .bold)
            NSImage(systemSymbolName: "trash.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)?
                .draw(in: box)
            return true
        }
        image.isTemplate = true
        return image
    }()

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(params: Shared.params, model: Shared.model, cycler: Shared.cycler)
        } label: {
            MenuLabel(model: Shared.model)
        }
    }
}

/// The status item's glyph. A view rather than a bare `Image`, so that arming
/// the Trash changes it — the mode has to be visible from outside the menu.
struct MenuLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: model.swallowAction == .moveToTrash
              ? BlackHoleApp.menuIconArmed : BlackHoleApp.menuIcon)
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
            // The cycler owns no timer while the widget is parked, and hides its
            // switches behind the panel's fade. Both are wired here rather than
            // held as references, so neither side has to know the other exists.
            Shared.widget.onRunningChange = { Shared.cycler.setSuspended(!$0) }
            Shared.cycler.performSwitch = { Shared.widget.crossfadeStyle($0) }
            HotKey.install { Shared.model.hidden.toggle() }
            Proximity.shared.setEnabled(Shared.model.noticesPointer)
            Shared.widget.isEnabled = true
            trapExitSignals()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // closing the Advanced window must not kill the widget
    }

    /// The one thing that must not be left behind.
    ///
    /// A capture stream outlives the process that started it: replayd keeps the
    /// session, its descriptors and the menu bar's recording indicator, and
    /// there is no longer a client anywhere that could ask it to stop. See
    /// `ScreenCapture.stopSynchronously` for what that costs after a few dozen
    /// quits. Everything else this app owns is either persisted as it changes
    /// or dies with the address space.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { ScreenCapture.shared.stopSynchronously() }
    }

    /// Ctrl-C is a quit too, as far as ScreenCaptureKit is concerned.
    ///
    /// `applicationWillTerminate` covers the menu's Quit and a logout; it does
    /// not cover `swift run` interrupted from the terminal, which is how this
    /// app is stopped most often *by a wide margin* during development and
    /// which leaks a capture session every single time. Both signals have to be
    /// ignored at the libc level first — the default disposition kills the
    /// process outright and the dispatch source never gets to run.
    private func trapExitSignals() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    ScreenCapture.shared.stopSynchronously()
                    // Through AppKit rather than exit(), so anything else with a
                    // termination handler still gets one.
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Held, or ARC cancels the sources the moment `trapExitSignals` returns.
    private var signalSources: [DispatchSourceSignal] = []
}

// -------------------------------------------------------------- app state --

/// Three sizes cover it.
enum WidgetSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var label: String {
        switch self {
        case .small:  return L("menu.size.small")
        case .medium: return L("menu.size.medium")
        case .large:  return L("menu.size.large")
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
            lensChosen = true
            ScreenCapture.shared.capturesAudio = audioReactive && lens == .screen
            onLensChange?()
        }
    }
    /// False until somebody has picked a lens themselves. The launch value is
    /// *inferred* and never written, so the absence of the stored key is what
    /// "has not decided yet" means — which is the only group the menu's
    /// first-run hint is for. Choosing either option, including choosing not to
    /// record, retires it for good.
    @Published private(set) var lensChosen: Bool
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
        return ScreenCapture.shared.isRunning ? nil : L("capture.starting")
    }

    var captureDenied: Bool {
        ScreenCapture.shared.permissionDenied
    }

    init() {
        let d = UserDefaults.standard
        // Restored, because the menu can still change them.
        hidden = d.bool(forKey: "hidden")
        size = d.object(forKey: "size") as? Double ?? WidgetSize.medium.points
        launchAtLogin = LoginItem.isEnabled   // system state, not a stored preference

        // The lens is restored, and when there is nothing to restore it is
        // *inferred* rather than defaulted.
        //
        // Pinning it to `.screen` meant the very first launch reached for
        // ScreenCaptureKit and macOS threw a Screen Recording prompt at somebody
        // who had not asked for anything yet. Defaulting it to `.stars` instead
        // would fix that and silently demote every existing user who had already
        // granted the permission — an update that turns your lensed screen into
        // a floating disk reads as a bug, not as a privacy improvement.
        //
        // `CGPreflightScreenCaptureAccess` answers without prompting, so the
        // absent case can be decided on what is actually true: already granted
        // means the lens works and should be on, not granted means start quiet
        // and let the menu offer it. Reading the stored value first is what
        // keeps that inference from overruling somebody who turned the lens off
        // on purpose — permission stays granted after they do.
        if let raw = d.string(forKey: "lens"), let stored = LensSource(rawValue: raw) {
            lens = stored
            lensChosen = true
        } else {
            lens = CGPreflightScreenCaptureAccess() ? .screen : .stars
            lensChosen = false
        }

        // Restored again, now that it has a menu item back. It was pinned while
        // it did not: a widget that eats files for real, with no way to see the
        // setting and no way to change it, is a trap. What makes it safe to
        // restore is not the menu item on its own — it is the menu item plus the
        // Trash sound at the moment a file moves and the menu-bar glyph that
        // changes while the mode is armed.
        swallowAction = (d.string(forKey: "swallowAction")
                            .flatMap(SwallowAction.init(rawValue:))) ?? .animateOnly

        // Deliberately *not* restored. These lost their menu items, so a stored
        // value could only ever be one somebody set before and can no longer
        // undo. The properties and their persistence stay, so restoring a menu
        // item restores the setting whole.
        frameRate = .fps60
        audioReactive = false
        position = .free
        noticesPointer = true
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
    @ObservedObject var cycler: StyleCycler
    @ObservedObject var updater = Shared.updater

    var body: some View {
        // Still the "only when there is something to say" band: what the lens
        // is doing is now a menu of its own, so all this has left to report is
        // a capture that is unhappy.
        if let status = model.captureStatus {
            Text(status)
            if model.captureDenied {
                Button(L("capture.askAgain")) {
                    ScreenCapture.shared.resetPermissionAndRetry()
                }
                Button(L("capture.openSettings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Divider()
        }

        // The first-run hint, and the only nagging this app does.
        //
        // Opt-in solved the permission prompt and created a second problem: a
        // widget that has never been asked to lens anything draws a disk over
        // nothing, which is a much duller object than the one the screenshots
        // show, and nobody in that state has any way of knowing what they are
        // missing. So the offer is made once — as a button, because pointing at
        // a menu somebody has not opened is not an offer — and it retires the
        // moment a lens is picked. Choosing *not* to record retires it too:
        // somebody who said no has answered the question, and asking again is
        // the behaviour opt-in existed to remove.
        if !model.lensChosen && model.lens == .stars {
            Button(L("menu.lens.hint")) { model.lens = .screen }
            Divider()
        }

        // Whether the screen is being recorded is the widget's most consequential
        // setting and the only one that costs a permission, so it is not hidden
        // behind Advanced and it is not conditional — it reads the same on the
        // way in as on the way out.
        Menu(L("menu.lens")) {
            // Inert text, above the choice it describes. A tooltip would be the
            // tidier place for it, but a status-bar menu is not a reliable one
            // to hang a tooltip on, and this has to be readable by the person
            // who opened the menu precisely because they did not know.
            Text(L("menu.lens.explain"))
            Divider()
            ForEach(LensSource.allCases) { source in
                Button(check(model.lens == source) + source.label) { model.lens = source }
            }
        }

        Menu(L("menu.size")) {
            ForEach(WidgetSize.allCases) { size in
                Button(check(WidgetSize.nearest(to: model.size) == size) + size.label) {
                    model.size = size.points
                }
            }
        }

        Menu(L("menu.style")) {
            ForEach(Specs.styles, id: \.0) { name, _ in
                Button(check(params.styleName == name) + name) { pick(name) }
            }
            if !params.customStyleNames.isEmpty {
                Divider()
                ForEach(params.customStyleNames, id: \.self) { name in
                    Button(check(params.styleName == name) + name) { pick(name) }
                }
            }
            Divider()
            // Saving does not stop the rotation. It is not a style change — the
            // look on screen is the one you were already looking at — and the
            // saved style joining the rotation is the point of saving it.
            Button(L("menu.style.saveAs")) {
                if let saved = StylePrompt.saveCurrent(into: params) {
                    cycler.styleAdded(saved)
                }
            }
            if params.customStyles[params.styleName] != nil {
                Button(L("menu.style.delete", params.styleName)) {
                    let name = params.styleName
                    params.deleteStyle(named: name)
                    cycler.styleRemoved(name)
                }
            }
        }

        // Beside Style rather than inside it. Nested under Style the submenu had
        // to sit below eight styles, the saved ones, and Save/Delete, and the
        // list you actually came to tick was the last thing on it.
        Menu(L("menu.cycle")) {
            ForEach(CycleInterval.allCases) { each in
                Button(check(cycler.interval == each) + each.label) {
                    cycler.interval = each
                }
            }
            Divider()
            ForEach(cycler.allStyleNames, id: \.self) { name in
                Button(check(cycler.selected.contains(name)) + name) {
                    cycler.toggle(name)
                }
            }
            Divider()
            Button(L("menu.cycle.all")) { cycler.selectAll() }
            Button(L("menu.cycle.none")) { cycler.selectNone() }
        }

        // What a dropped file is actually for. The default eats nothing, and
        // arming the other one is the only irreversible thing this widget can be
        // told to do, so it asks the first time — see `TrashPrompt`.
        Menu(L("menu.swallow")) {
            ForEach(SwallowAction.allCases) { action in
                Button(check(model.swallowAction == action) + action.label) {
                    arm(action)
                }
            }
        }

        // Lens, Size, Style, Cycle. Everything else the widget can do — where it
        // sits, how fast it redraws, whether it swallows the pointer, what
        // becomes of a dropped file — has a default worth shipping, and listing
        // all of them made an ornament read as a control panel. The settings
        // still exist; `AppModel` pins them to their defaults now rather than
        // restoring whatever was last chosen, because a value nobody can see is
        // a value nobody can put back. The lens is the exception that came back:
        // it is the one setting that costs a permission.
        Divider()

        Button(model.hidden ? L("menu.show") : L("menu.hide")) { model.hidden.toggle() }
        // Checks happen on their own once a day; this is for when you want to
        // know now. Disabled while a check is already running — see `Updater`.
        Button(L("menu.checkUpdates")) { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
        Button(check(model.launchAtLogin) + L("menu.launchAtLogin")) {
            model.launchAtLogin.toggle()
        }
        Button(L("menu.advanced")) { Shared.advanced.show() }
        Button(L("menu.about")) { AboutPanel.show() }
        Button(L("menu.quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    /// SwiftUI menus in a MenuBarExtra do not render a selection state on
    /// Buttons, so the current choice is marked in the title itself.
    private func check(_ on: Bool) -> String { on ? "✓ " : "   " }

    /// Choosing a style by hand stops the rotation. Leaving it running would
    /// take the choice away again at the next boundary with nothing on screen
    /// to say why — and the cycler's own switches must not come through here,
    /// or the first one would turn the cycle off.
    private func pick(_ name: String) {
        cycler.stop()
        params.apply(style: name)
    }

    /// Turning the Trash on is the one setting here that can lose you something,
    /// so the first time it is chosen it has to be *chosen*, not brushed past on
    /// the way down a menu. Once confirmed it never asks again: the sound and
    /// the changed menu-bar glyph are what carry the state from then on.
    private func arm(_ action: SwallowAction) {
        guard action == .moveToTrash, !TrashPrompt.confirmed else {
            model.swallowAction = action
            return
        }
        if TrashPrompt.confirm() { model.swallowAction = action }
    }
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
                rootView: AdvancedPanel(params: Shared.params, model: Shared.model,
                                        cycler: Shared.cycler))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}


// ------------------------------------------------------------ trash prompt --

/// Asked once, the first time anybody arms the Trash.
///
/// A menu-bar app has no window to hang a sheet on, so this is a plain modal
/// alert — the same reason `StylePrompt` is one. The destructive button is not
/// the default: this dialog exists because the setting is easy to pick by
/// accident, and a default-focused "Move to Trash" would reintroduce exactly
/// that.
@MainActor
enum TrashPrompt {
    private static let key = "swallowTrashConfirmed"

    static var confirmed: Bool { UserDefaults.standard.bool(forKey: key) }

    /// True if it should be armed.
    static func confirm() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("trash.confirm.title")
        alert.informativeText = L("trash.confirm.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("trash.confirm.cancel"))
        alert.addButton(withTitle: L("trash.confirm.ok"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }
}

// ------------------------------------------------------------------ about --

/// The system's own About panel, not one of ours.
///
/// It reads the name, icon, version and copyright straight out of `Info.plist`,
/// lays them out the way every other Mac app's does, and is localized by the
/// system — three things a hand-built window would have to redo and would get
/// subtly wrong. The only part worth supplying is the credits, which is where
/// the licence and the repository go.
///
/// `activate` first: with `.accessory` there is no Dock icon to bounce and no
/// app menu to have come from, so an un-activated panel opens behind whatever
/// is in front.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var credits: NSAttributedString {
        let body = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        body.append(NSAttributedString(string: L("about.blurb") + "\n\n", attributes: base))
        var link = base
        link[.link] = URL(string: "https://github.com/ZGhey/blackhole-mac")!
        body.append(NSAttributedString(string: "github.com/ZGhey/blackhole-mac", attributes: link))
        body.append(NSAttributedString(string: "\n" + L("about.licence"), attributes: base))
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        body.addAttribute(.paragraphStyle, value: centred,
                          range: NSRange(location: 0, length: body.length))
        return body
    }
}

// -------------------------------------------------------------- style save --

/// Asking for a name. A menu-bar app has no window to hang a sheet on, so this
/// is a plain modal alert — the one moment the app is allowed to interrupt.
@MainActor
enum StylePrompt {
    /// The name it was saved under, or nil if the sheet was cancelled.
    @discardableResult
    static func saveCurrent(into params: Params) -> String? {
        let alert = NSAlert()
        alert.messageText = L("style.save.title")
        alert.informativeText = L("style.save.message")
        alert.addButton(withTitle: L("style.save.ok"))
        alert.addButton(withTitle: L("style.save.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = params.customStyles[params.styleName] != nil
            ? params.styleName : L("style.save.copy", params.styleName)
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        params.saveCurrentStyle(named: field.stringValue)
        // `saveCurrentStyle` trims and rejects an empty name, so the name that
        // stuck is the one on `params`, not the one in the field.
        return params.customStyles[params.styleName] != nil ? params.styleName : nil
    }
}
