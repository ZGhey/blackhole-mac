import Foundation

/// One short name for "the translation of this key".
///
/// There is no language-detection code here and there should not be: macOS
/// already matches the system's preferred languages against the localizations a
/// bundle actually contains, and a hand-rolled check would fight the per-app
/// language override in System Settings rather than respect it.
///
/// `Bundle.module`, not `.main`: the strings ship in the SwiftPM resource
/// bundle, which is the only copy that exists under `swift run`. `make-app.sh`
/// also mirrors the `.lproj` folders into `Contents/Resources` so that macOS
/// lists the app as localized and offers it in the per-app language picker —
/// the lookup below is unaffected either way.
func L(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
}

/// The formatting overload, for the two strings that carry a style name.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}
