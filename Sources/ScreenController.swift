import AppKit

/// Owns the two overlay windows for one display.
final class ScreenController {
    let screen: NSScreen
    let space: ScreenSpace
    let engine: SnowEngine

    private var back: OverlayWindow?
    private var front: OverlayWindow?

    init?(screen: NSScreen, mainHeight: CGFloat, density: SnowDensity) {
        self.screen = screen
        self.space = ScreenSpace(screen: screen, mainHeight: mainHeight)
        self.engine = SnowEngine(space: space, density: density)

        guard let b = OverlayWindow(screen: screen, engine: engine, layer: .back),
              let f = OverlayWindow(screen: screen, engine: engine, layer: .front) else {
            return nil
        }

        self.back = b
        self.front = f
        b.orderFrontRegardless()
        f.orderFrontRegardless()
    }

    func setDensity(_ d: SnowDensity) { engine.setDensity(d) }
    func clearSnow() { engine.clearSnow() }

    func setVisible(_ visible: Bool) {
        if visible {
            back?.metalView.isPaused = false
            front?.metalView.isPaused = false
            back?.orderFrontRegardless()
            front?.orderFrontRegardless()
        } else {
            back?.orderOut(nil)
            front?.orderOut(nil)
            back?.metalView.isPaused = true
            front?.metalView.isPaused = true
        }
    }

    func close() {
        back?.orderOut(nil)
        front?.orderOut(nil)
        back = nil
        front = nil
    }
}
