import AppKit
import Carbon.HIToolbox

/// A single global hot key, via the Carbon API.
///
/// Deliberately not an `NSEvent` global monitor: those need the Accessibility
/// permission for key events, and a widget you want to hide should not demand
/// the right to watch everything you type. `RegisterEventHotKey` needs nothing.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: () -> Void = {}
    private static var shared: HotKey?

    /// ⌥⌘B — B for black hole, and unclaimed in every app worth worrying about.
    static func install(_ action: @escaping () -> Void) {
        let hk = HotKey()
        hk.action = action
        hk.register(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey | cmdKey))
        shared = hk
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in HotKey.shared?.action() }
            return noErr
        }, 1, &spec, nil, &handler)

        let id = EventHotKeyID(signature: OSType(0x424C4B48), id: 1)   // 'BLKH'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
