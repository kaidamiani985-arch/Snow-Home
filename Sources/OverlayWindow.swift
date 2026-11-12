import AppKit
import Metal
import MetalKit

final class OverlayWindow: NSWindow {
    let metalView: MTKView

    static func makeView(device: MTLDevice, screen: NSScreen, samples: Int) -> MTKView {
        let frame = CGRect(origin: .zero, size: screen.frame.size)
        let view = MTKView(frame: frame, device: device)
        view.sampleCount = samples
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = CGColor.clear
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        return view
    }

    init(screen: NSScreen, view: MTKView, layer: SnowLayer) {
        self.metalView = view
        let frame = CGRect(origin: .zero, size: screen.frame.size)

        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.animationBehavior = .none
        self.acceptsMouseMovedEvents = false
        self.isReleasedWhenClosed = false
        self.level = OverlayWindow.level(for: layer)
        // Deliberately no `.fullScreenAuxiliary`: the overlay should not follow
        // into another app's full-screen space.
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        self.contentView = view
        self.setFrame(frame, display: false)
        view.frame = CGRect(origin: .zero, size: frame.size)
    }

    private static func level(for layer: SnowLayer) -> NSWindow.Level {
        switch layer {
        case .back:
            // Above the wallpaper and above the desktop icons, still far below
            // every app window.
            let raw = CGWindowLevelForKey(.desktopIconWindow) + 1
            return NSWindow.Level(rawValue: Int(raw))
        case .front:
            // Above the menu bar background (24) and its item windows (25) so a
            // cap on a window that is flush with the top of the screen is still
            // visible. Below the notch/status overlays at 27.
            let raw = CGWindowLevelForKey(.mainMenuWindow) + 2
            return NSWindow.Level(rawValue: Int(raw))
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
