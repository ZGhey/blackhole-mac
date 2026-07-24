import AppKit
import MetalKit
import QuartzCore
import SwiftUI

/// The renderer plus the app state it depends on.
///
/// MetalView takes the lens as a plain value, so something has to observe
/// AppModel and hand it a fresh one. Inside an NSHostingView there is no
/// enclosing SwiftUI view to do that, which is exactly what the widget is —
/// hence this wrapper.
struct RenderView: View {
    @ObservedObject var params: Params
    @ObservedObject var model: AppModel

    var body: some View {
        MetalView(params: params, lens: model.lens,
                  onError: { model.rendererError = $0 })
    }
}

/// Hosts the MTKView and keeps the renderer fed from SwiftUI state.
struct MetalView: NSViewRepresentable {
    @ObservedObject var params: Params
    let lens: LensSource
    /// Startup failures (a Metal shader typo, most likely) surface in the UI
    /// rather than as a silently black window.
    let onError: (String) -> Void

    final class Coordinator {
        var renderer: Renderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        let renderer: Renderer
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError.noDevice }
            renderer = try Renderer(device: device, params: params)
            view.device = device
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            FileHandle.standardError.write("renderer: \(message)\n".data(using: .utf8)!)
            DispatchQueue.main.async { onError(message) }
            return view
        }
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        // A widget-sized panel is a fraction of a screen's pixels, so it runs at
        // the display's own rate without a frame cap.
        view.preferredFramesPerSecond = 60
        // The drawable has to carry alpha all the way to the compositor, or the
        // transparent parts of the widget come out black.
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.isOpaque = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        context.coordinator.renderer = renderer

        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        renderer.params = params
        renderer.lens = lens
    }
}
