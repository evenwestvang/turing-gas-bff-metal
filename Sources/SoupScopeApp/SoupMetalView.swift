#if canImport(SwiftUI) && canImport(MetalKit) && canImport(AppKit)
import SwiftUI
import Metal
import MetalKit
import AppKit
import SoupScopeCore

/// MTKView subclass that turns mouse/trackpad events into camera operations.
/// Coordinates are converted into the renderer's convention — drawable pixels,
/// top-left origin, +y down — accounting for the window's backing scale so pan and
/// zoom track the cursor exactly on Retina displays.
final class SoupMTKView: MTKView {
    weak var appModel: AppModel?
    private var lastDrag: (x: Double, y: Double)?

    override var acceptsFirstResponder: Bool { true }

    private var backingScale: Double {
        Double(window?.backingScaleFactor ?? layer?.contentsScale ?? 2.0)
    }

    /// Event location → drawable-pixel, top-left-origin coordinates.
    private func pixel(of event: NSEvent) -> (x: Double, y: Double) {
        let local = convert(event.locationInWindow, from: nil) // points, bottom-left origin
        let scale = backingScale
        let x = Double(local.x) * scale
        let y = Double(bounds.height - local.y) * scale         // flip to top-left, y-down
        return (x, y)
    }

    override func scrollWheel(with event: NSEvent) {
        let (px, py) = pixel(of: event)
        let delta = event.hasPreciseScrollingDeltas
            ? Double(event.scrollingDeltaY)
            : Double(event.deltaY) * 10
        let factor = exp(delta * 0.0025)          // exponential, cursor-anchored zoom
        appModel?.zoom(factor: factor, anchorPxX: px, anchorPxY: py)
    }

    override func magnify(with event: NSEvent) {
        let (px, py) = pixel(of: event)
        appModel?.zoom(factor: 1.0 + Double(event.magnification), anchorPxX: px, anchorPxY: py)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDrag = pixel(of: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let cur = pixel(of: event)
        if let last = lastDrag {
            appModel?.pan(dxPx: cur.x - last.x, dyPx: cur.y - last.y)
        }
        lastDrag = cur
    }

    override func mouseUp(with event: NSEvent) { lastDrag = nil }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " "?: appModel?.togglePause()
        case "f"?, "F"?: appModel?.fitAll()
        case "m"?, "M"?: appModel?.cycleMetricChannel()
        case "r"?, "R"?: appModel?.resetInteractiveResidentSimulation()
        default: super.keyDown(with: event)
        }
    }
}

/// SwiftUI wrapper for the Metal soup view. The MTKView's delegate (`Renderer`) is
/// held by the coordinator because `MTKView.delegate` is weak; its lifetime is
/// therefore stable across SwiftUI updates.
struct SoupMetalView: NSViewRepresentable {
    let appModel: AppModel

    final class Coordinator {
        let renderer: Renderer?
        init(renderer: Renderer?) { self.renderer = renderer }
    }

    func makeCoordinator() -> Coordinator {
        if let context = appModel.context {
            return Coordinator(renderer: Renderer(appModel: appModel, context: context))
        }
        return Coordinator(renderer: nil)
    }

    func makeNSView(context: Context) -> SoupMTKView {
        // Use the shared device when available; otherwise a default device just so
        // the view can clear itself while the HUD shows the error.
        let device = appModel.context?.device ?? MTLCreateSystemDefaultDevice()
        let view = SoupMTKView(frame: .zero, device: device)
        view.appModel = appModel
        view.colorPixelFormat = .bgra8Unorm
        let bg = SoupVisualizationTheme.background
        view.clearColor = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false                    // continuous, display-link driven
        view.delegate = context.coordinator.renderer
        return view
    }

    func updateNSView(_ nsView: SoupMTKView, context: Context) {
        nsView.appModel = appModel
    }
}
#endif
