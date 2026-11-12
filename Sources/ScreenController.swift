import AppKit
import Metal
import MetalKit

/// Owns the two overlay windows for one display and one active season.
final class ScreenController {
    let screen: NSScreen
    let space: ScreenSpace
    let engine: SeasonEngine

    private var back: OverlayWindow?
    private var front: OverlayWindow?
    private var renderers: [MTKViewDelegate] = []

    init?(screen: NSScreen, mainHeight: CGFloat, season: Season, density: SnowDensity) {
        self.screen = screen
        self.space = ScreenSpace(screen: screen, mainHeight: mainHeight)

        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let samples = 2
        let backView = OverlayWindow.makeView(device: device, screen: screen, samples: samples)
        let frontView = OverlayWindow.makeView(device: device, screen: screen, samples: samples)

        switch season {
        case .snow:
            let engine = SnowEngine(space: space, density: density)
            self.engine = engine
            guard let br = SnowRenderer(device: device, engine: engine,
                                        layer: .back, sampleCount: samples),
                  let fr = SnowRenderer(device: device, engine: engine,
                                        layer: .front, sampleCount: samples) else { return nil }
            backView.delegate = br
            frontView.delegate = fr
            renderers = [br, fr]
        case .autumn:
            let engine = AutumnEngine(space: space, density: density)
            self.engine = engine
            guard let br = AutumnRenderer(device: device, engine: engine,
                                          layer: .back, sampleCount: samples),
                  let fr = AutumnRenderer(device: device, engine: engine,
                                          layer: .front, sampleCount: samples) else { return nil }
            backView.delegate = br
            frontView.delegate = fr
            renderers = [br, fr]
        }

        let b = OverlayWindow(screen: screen, view: backView, layer: .back)
        let f = OverlayWindow(screen: screen, view: frontView, layer: .front)
        self.back = b
        self.front = f
        b.orderFrontRegardless()
        f.orderFrontRegardless()
    }

    func setDensity(_ d: SnowDensity) { engine.setDensity(d) }
    func clear() { engine.clear() }
    func setNeverDisappear(_ value: Bool) { engine.setNeverDisappear(value) }

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
