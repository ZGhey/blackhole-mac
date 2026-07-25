import CoreGraphics

/// How the background texture maps into the widget: `uv * scale + off`.
public struct BackgroundFit {
    public var scaleX: Float = 1
    public var scaleY: Float = 1
    public var offX: Float = 0
    public var offY: Float = 0

    public init(scaleX: Float = 1, scaleY: Float = 1, offX: Float = 0, offY: Float = 0) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offX = offX
        self.offY = offY
    }

    /// Maps the widget's own rect into a full-display screen capture, so the
    /// shader samples exactly the pixels it is covering. The capture texture and
    /// the shader's uv both run top-down; `NSWindow.frame` does not, hence the
    /// y flip. Unused when the stream is cropped to the widget already.
    ///
    /// Takes `CGRect`, which on this platform *is* `NSRect` — the caller passes
    /// window frames straight in and no AppKit shim is needed either side.
    public static func screenRect(window: CGRect, display: CGRect) -> BackgroundFit {
        guard display.width > 0, display.height > 0 else { return BackgroundFit() }
        return BackgroundFit(
            scaleX: Float(window.width / display.width),
            scaleY: Float(window.height / display.height),
            offX: Float((window.minX - display.minX) / display.width),
            offY: Float((display.maxY - window.maxY) / display.height))
    }
}
