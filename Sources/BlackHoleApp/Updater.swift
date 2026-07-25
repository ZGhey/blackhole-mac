import AppKit
import Combine
import Sparkle

/// Checking for, and installing, new versions.
///
/// Replacing an app while it is running is the part of this that is easy to get
/// wrong — download, verify, unpack, swap, relaunch, and do it without leaving a
/// half-installed bundle behind if the power goes out in the middle. Sparkle
/// does all of that; what matters here is that it refuses to install anything
/// whose EdDSA signature does not match `SUPublicEDKey` in the Info.plist. The
/// app is self-signed rather than notarized, so that check is the whole of the
/// trust story: without it, whoever can write to where the appcast points can
/// hand this machine an executable.
///
/// The feed and the key live in the Info.plist that `make-app.sh` writes, which
/// is also why updates only work from the bundled app — under `swift run` there
/// is no Info.plist, and `canCheckForUpdates` stays false.
@MainActor
final class Updater: ObservableObject {
    /// Bound to the menu item, so "Check for Updates…" is greyed out while a
    /// check is already in flight rather than starting a second one.
    @Published private(set) var canCheck = false

    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true — the scheduled check begins with the app. The
        // interval and whether it installs on its own are Info.plist policy
        // (SUScheduledCheckInterval, SUAutomaticallyUpdate), not decisions this
        // class should be making.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheck)
    }

    /// A menu-bar-only app is never the active application, and Sparkle's
    /// windows would open behind whatever is. Activating first is what puts the
    /// dialogue in front of the person who just asked for it.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }
}
