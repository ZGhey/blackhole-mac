import AppKit

/// System preferences the widget is obliged to respect.
///
/// Neither of these is visible when it does not apply, which is the point. An
/// ornament that ignores "reduce motion" is not charming, it is the thing that
/// particular setting exists to turn off; and one that keeps integrating
/// geodesics at full rate on a draining battery is answering a question nobody
/// asked.
@MainActor
final class SystemState: ObservableObject {
    static let shared = SystemState()

    /// Stop the wandering. The disk still turns — that is the content, not
    /// incidental movement — but the widget stops travelling around the screen.
    @Published private(set) var reduceMotion = false
    /// Fewer integration steps and half the frame rate.
    @Published private(set) var lowPower = false

    private init() {
        refresh()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// What the renderer should actually use, given the user's setting.
    func frameRate(preferred: Int) -> Int { lowPower ? min(preferred, 30) : preferred }
    func steps(preferred: Float) -> Float { lowPower ? max(preferred * 0.6, 12) : preferred }
}
