import AppKit
import QuartzCore
import simd

enum SnowDensity: Int, CaseIterable {
    case light = 0
    case normal = 1
    case heavy = 2

    var flakeCount: Int {
        switch self {
        case .light: return 900
        case .normal: return 2200
        case .heavy: return 3800
        }
    }

    var label: String {
        switch self {
        case .light: return "Light"
        case .normal: return "Normal"
        case .heavy: return "Heavy"
        }
    }
}

/// A horizontal surface snow can settle on: either the bottom of the screen
/// or the top edge of a window. Accumulation is a 1-D height profile along
/// that edge, which is exactly what a 2-D side-on snowfall looks like.
final class Platform {
    static let cell: Float = 2.0
    static let defaultMaxHeight: Float = 26.0
    /// How tall this surface is allowed to pile. The Dock's limit grows over
    /// time so a long session builds a proper snow bank.
    var maxHeight: Float = Platform.defaultMaxHeight

    let id: CGWindowID?
    var layer: SnowLayer
    var x0: Float
    var edgeY: Float
    var width: Float
    var heights: [Float]
    var occluded: [Bool]
    var rough: [Float]
    var baseOffsets: [Float]
    var spillLeft: Float = 0
    var spillRight: Float = 0
    /// Fraction of maxHeight at which the cap starts spilling over its ends.
    var shedFraction: Float = 0.78
    /// Desktop file icon: snow sits on its artwork silhouette and piles higher.
    var isIcon: Bool = false
    let noiseSeed: Float
    var zIndex: Int
    var isDock: Bool
    var lastX0: Float
    var lastEdgeY: Float
    var lastShed: CFTimeInterval = 0
    /// Earliest time the cap may release another icon avalanche.
    var nextSpill: CFTimeInterval = 0
    /// Earliest time the next small edge cluster may crumble off.
    var nextEdgeShed: CFTimeInterval = 0
    var renderCap: Float = 10_000

    init(id: CGWindowID?, layer: SnowLayer, x0: Float, edgeY: Float,
         width: Float, zIndex: Int, isDock: Bool) {
        self.id = id
        self.layer = layer
        self.x0 = x0
        self.edgeY = edgeY
        self.width = width
        self.zIndex = zIndex
        self.isDock = isDock
        self.lastX0 = x0
        self.lastEdgeY = edgeY
        self.noiseSeed = Float.random(in: 0...6.283)
        let n = max(2, Int(ceil(width / Platform.cell)))
        self.heights = [Float](repeating: 0, count: n)
        self.occluded = [Bool](repeating: false, count: n)
        self.rough = Platform.makeRough(count: n, seed: noiseSeed)
        self.baseOffsets = [Float](repeating: 0, count: n)
    }

    /// Smooth low-frequency variation so a saturated cap still has peaks and
    /// hollows instead of a machined flat top.
    private static func makeRough(count: Int, seed: Float) -> [Float] {
        var r = [Float](repeating: 1, count: count)
        for i in 0..<count {
            let t = Float(i)
            let v = 0.55 * sin(t * 0.21 + seed)
                  + 0.30 * sin(t * 0.53 + seed * 1.7)
                  + 0.15 * sin(t * 0.11 + seed * 0.6)
            r[i] = 1.0 + v * 0.30
        }
        return r
    }

    func setWidth(_ newWidth: Float) {
        width = max(2, newWidth)
        let n = max(2, Int(ceil(width / Platform.cell)))
        if n != heights.count {
            var h = [Float](repeating: 0, count: n)
            let m = min(n, heights.count)
            if m > 0 { for i in 0..<m { h[i] = heights[i] } }
            heights = h
            occluded = [Bool](repeating: false, count: n)
            rough = Platform.makeRough(count: n, seed: noiseSeed)
            baseOffsets = [Float](repeating: 0, count: n)
        } else if occluded.count != n {
            occluded = [Bool](repeating: false, count: n)
        }
    }

    @inline(__always)
    func deposit(_ x: Float, _ amount: Float) {
        let idx = Int((x - x0) / Platform.cell)
        guard idx >= 0 && idx < heights.count else { return }
        // Spread each landing across a few columns so the cap reads as a
        // continuous drift instead of isolated spikes.
        let kernel: [Float] = [0.02, 0.05, 0.10, 0.17, 0.32, 0.17, 0.10, 0.05, 0.02]
        for k in 0..<9 {
            let j = idx + k - 4
            guard j >= 0 && j < heights.count else { continue }
            heights[j] = min(heights[j] + amount * kernel[k], maxHeight)
        }
    }

    /// Lowest point of the artwork's top edge. Snow on a folder's body starts
    /// further down than snow on its tab.
    var maxBaseOffset: Float {
        var m: Float = 0
        for o in baseOffsets where o > m { m = o }
        return m
    }

    var totalSnow: Float {
        var t: Float = 0
        for h in heights { t += h }
        return t
    }
}

struct Flake {
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var size: Float = 2
    var alpha: Float = 0.8
    var rot: Float = 0
    var spin: Float = 0
    var seed: Float = 0
    var near: Bool = false
    var enabled: Bool = true
    var isClump: Bool = false
    var mass: Float = 0
    var drift: Float = 0
    var windFactor: Float = 1
    var terminal: Float = 68
    /// Platform this grain was shaken from. It must not land straight back on
    /// top of the window it just left.
    var ignoreID: CGWindowID? = nil
}

final class SnowEngine {
    let space: ScreenSpace
    let width: Float
    let height: Float

    private(set) var platforms: [CGWindowID: Platform] = [:]
    private var ground: Platform

    private var flakes: [Flake] = []
    /// Snow that has broken loose from a drift. These are separate from the
    /// ambient field so a trickle off a window never steals falling snow from
    /// the sky. They are simulated as individual sand grains.
    private var grains: [Flake] = []
    private var grainRecycleIndex = 0
    private var density: SnowDensity
    private var recycleIndex = 0

    private var lastStep: CFTimeInterval = 0
    private var iconIDs: [String: CGWindowID] = [:]
    private var nextIconID: CGWindowID = 900_000
    private let dockPlatformID = CGWindowID(0)
    private var time: Float = 0
    private var cursor: CGPoint = .zero
    private var cursorVisible = false
    private var lastCursor: CGPoint = .zero
    private var hasLastCursor = false
    private var lastPloughX: Float = 0
    private var hasLastPlough = false
    private var intensity: Float = 1.0
    /// Whole-screen budget for automatic icon avalanches. Interaction-driven
    /// grains bypass this so pushing snow still feels immediate.
    private var nextAmbientClump: CFTimeInterval = 0

    /// Runtime-tunable so the icon piles can be adjusted without rebuilding
    /// (and without invalidating the Accessibility grant).
    private let iconDeposit: Float = SnowEngine.setting("iconDeposit", default: 1.2)
    private let iconMaxHeight: Float = SnowEngine.setting("iconMaxHeight", default: 20)

    private static func setting(_ key: String, default value: Float) -> Float {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? Float(v) : value
    }

    // Output for the renderers.
    private(set) var backFlakes: [FlakeInstance] = []
    private(set) var frontFlakes: [FlakeInstance] = []
    private(set) var backDrift: [DriftVertex] = []
    private(set) var frontDrift: [DriftVertex] = []

    init(space: ScreenSpace, density: SnowDensity) {
        self.space = space
        self.width = Float(space.size.width)
        self.height = Float(space.size.height)
        self.density = density
        self.ground = Platform(id: nil, layer: .back, x0: 0, edgeY: Float(space.size.height),
                               width: Float(space.size.width), zIndex: 9999, isDock: false)
        var grainPool = [Flake](repeating: Flake(), count: 2400)
        for i in grainPool.indices { grainPool[i].enabled = false }
        self.grains = grainPool
        rebuildFlakes(count: density.flakeCount, spread: true)
    }

    // MARK: - Public

    func setDensity(_ d: SnowDensity) {
        guard d != density else { return }
        density = d
        rebuildFlakes(count: d.flakeCount, spread: false)
    }

    var currentDensity: SnowDensity { density }

    func clearSnow() {
        ground.heights = [Float](repeating: 0, count: ground.heights.count)
        for p in platforms.values {
            p.heights = [Float](repeating: 0, count: p.heights.count)
        }
        for i in grains.indices { grains[i].enabled = false }
        for i in flakes.indices {
            respawn(&flakes[i], atTop: true, forceLayer: nil)
        }
    }

    func stepIfNeeded(_ now: CFTimeInterval) {
        let dt = now - lastStep
        guard dt >= 1.0 / 70.0 else { return }
        lastStep = now
        step(min(Float(dt), 1.0 / 20.0), now: now)
    }

    // MARK: - Setup

    private func rebuildFlakes(count: Int, spread: Bool) {
        var arr = [Flake](repeating: Flake(), count: count)
        for i in 0..<count {
            var f = Flake()
            respawn(&f, atTop: !spread, forceLayer: nil)
            if spread {
                f.y = Float.random(in: 0...max(1, height))
                f.vy = Float.random(in: 15...55)
            }
            arr[i] = f
        }
        flakes = arr
        recycleIndex = 0
    }

    private func respawn(_ f: inout Flake, atTop: Bool, forceLayer: Bool?) {
        f.x = Float.random(in: -20...(width + 20))
        f.y = atTop ? -Float.random(in: 2...40) : Float.random(in: 0...max(1, height))
        f.vx = Float.random(in: -8...8)
        f.vy = Float.random(in: 10...45)
        f.seed = Float.random(in: 0..<1)
        f.rot = Float.random(in: 0..<6.283)
        f.spin = Float.random(in: -0.8...0.8)
        f.isClump = false
        f.mass = 0
        f.enabled = Float.random(in: 0..<1) < intensity
        // Every flake gets its own air resistance, drift and wind sensitivity,
        // otherwise the whole field moves as one sheet.
        f.drift = Float.random(in: -15...15)
        f.windFactor = Float.random(in: 0.2...0.9)
        f.terminal = Float.random(in: 32...112)

        if let forced = forceLayer {
            f.near = forced
        } else {
            f.near = Float.random(in: 0..<1) < 0.18
        }

        if f.near {
            f.size = Float.random(in: 1.0...2.0)
            f.alpha = Float.random(in: 0.18...0.42)
        } else {
            f.size = Float.random(in: 1.4...3.4)
            f.alpha = Float.random(in: 0.55...0.95)
        }
    }

    // MARK: - Simulation

    private func step(_ dt: Float, now: CFTimeInterval) {
        time += dt
        updateCursor()

        SpaceMonitor.shared.refreshIfNeeded(now: now)
        if SpaceMonitor.shared.isFullScreen {
            // Stay completely out of the way of a full-screen app, including the
            // Dock, which macOS does not draw in that Space.
            backFlakes.removeAll(keepingCapacity: true)
            frontFlakes.removeAll(keepingCapacity: true)
            backDrift.removeAll(keepingCapacity: true)
            frontDrift.removeAll(keepingCapacity: true)
            hasLastCursor = false
            return
        }

        WindowTracker.shared.refreshIfNeeded(now: now)
        syncPlatforms(now: now)


        let gravity: Float = 46

        // Slow weather: snowfall density drifts over tens of seconds, with
        // occasional gusts that change the wind direction. The wind stays
        // gentle so flakes still fall mostly downward instead of streaking
        // sideways across the screen.
        intensity = max(0.18, min(1.0,
            0.62 + 0.30 * sin(time * 0.16) + 0.12 * sin(time * 0.42 + 1.7)))
        let gust = 16 * pow(max(0, sin(time * 0.11 + 0.6)), 6)
        let windBase = 7 * sin(time * 0.07)
                     + 5 * sin(time * 0.19 + 1.3)
                     + 3 * sin(time * 0.47 + 0.4)
                     + gust

        for i in flakes.indices {
            var f = flakes[i]

            if !f.enabled {
                // Parked flake: still cycles so density can recover later.
                f.y += 320 * dt
                if f.y > height + 40 {
                    respawn(&f, atTop: true, forceLayer: nil)
                }
                flakes[i] = f
                continue
            }

            let prevY = f.y
            let phase = f.seed * 6.283

            if f.isClump {
                // A pushed-off chunk: heavy, little wind influence.
                f.vy += gravity * 1.8 * dt
                if f.vy > 260 { f.vy = 260 }
                f.x += f.vx * dt
                f.y += f.vy * dt
                f.rot += f.spin * dt
            } else {
                let targetVX = windBase * f.windFactor + f.drift
                            + 5 * sin(time * 0.6 + phase)
                // Never let a slow flake drift sideways faster than it falls.
                // That was what made the field look like it was being shot
                // across the screen instead of snowing.
                let maxDrift = f.terminal * 0.6
                let clampedVX = max(-maxDrift, min(maxDrift, targetVX))
                f.vx += (clampedVX - f.vx) * min(1, dt * 1.1)
                f.vy += gravity * dt
                if f.vy > f.terminal { f.vy = f.terminal }

                f.x += (f.vx + sin(time * 1.9 + phase) * 2) * dt
                f.y += f.vy * dt
                f.rot += f.spin * dt
            }

            if f.x < -30 { f.x = width + 25 }
            if f.x > width + 30 { f.x = -25 }

            if f.near {
                if let p = firstPlatformCrossed(from: prevY, to: f.y, x: f.x, layer: .front) {
                    p.deposit(f.x, f.isClump ? max(1.0, f.mass) : 2.0)
                    respawn(&f, atTop: true, forceLayer: true)
                } else {
                    let surf = surfaceY(ground, x: f.x)
                    if f.y >= surf {
                        ground.deposit(f.x, f.isClump ? max(1.0, f.mass) : 1.2)
                        respawn(&f, atTop: true, forceLayer: true)
                    }
                }
            } else {
                // Far snow settles on the Dock too, otherwise the bottom of the
                // screen would be the only place it ever piles up.
                var landed = false

                // A window in front of the desktop catches the far plane too:
                // the flake disappears behind the window's top edge and builds
                // its cap, instead of falling all the way to the ground.
                if let p = firstPlatformCrossed(from: prevY, to: f.y, x: f.x, layer: .front) {
                    p.deposit(f.x, p.isDock ? 2.0 : 1.2)
                    landed = true
                }

                // Desktop icons live on the back plane. Their platforms follow
                // the artwork silhouette, so snow only lands on the icon body
                // and not on the transparent corners of its 64 pt cell.
                if !landed, let p = firstPlatformCrossed(from: prevY, to: f.y, x: f.x, layer: .back) {
                    p.deposit(f.x, p.isIcon ? iconDeposit : 1.2)
                    landed = true
                }

                if !landed {
                    let surf = surfaceY(ground, x: f.x)
                    if f.y >= surf && prevY <= height + 8 {
                        ground.deposit(f.x, 1.0)
                        landed = true
                    }
                }
                if landed {
                    respawn(&f, atTop: true, forceLayer: false)
                }
            }

            flakes[i] = f
        }

        ploughWithCursor(dt: dt)

        updateSurface(ground, dt: dt, now: now)
        for p in platforms.values { updateSurface(p, dt: dt, now: now) }
        updateGrains(dt: dt, gravity: gravity)

        buildVertices()
    }

    private func updateCursor() {
        cursor = ScreenGeometry.cursorLocal(in: space)
        cursorVisible = cursor.x >= -2 && cursor.x <= CGFloat(width) + 2
            && cursor.y >= -2 && cursor.y <= CGFloat(height) + 2
    }

    /// Y coordinate of the top of whatever snow is already sitting on `p` at x.
    private func surfaceY(_ p: Platform, x: Float) -> Float {
        let idx = Int((x - p.x0) / Platform.cell)
        guard idx >= 0 && idx < p.heights.count else { return p.edgeY }
        let base = p.edgeY + (idx < p.baseOffsets.count ? p.baseOffsets[idx] : 0)
        return base - p.heights[idx]
    }

    /// First platform surface the flake reaches this frame. Uses the top of the
    /// existing drift so flakes land on the pile instead of sinking through it.
    private func firstPlatformCrossed(from prevY: Float, to y: Float, x: Float,
                                      layer: SnowLayer,
                                      ignoring: CGWindowID? = nil) -> Platform? {
        var best: Platform?
        var bestSurface: Float = .greatestFiniteMagnitude

        for p in platforms.values where p.layer == layer {
            if let ignoring, p.id == ignoring { continue }
            guard x >= p.x0 && x <= p.x0 + p.width else { continue }
            let surface = surfaceY(p, x: x)
            guard y >= surface, prevY <= p.edgeY + p.maxBaseOffset + 8 else { continue }
            if surface < bestSurface {
                bestSurface = surface
                best = p
            }
        }
        return best
    }

    // MARK: - Platform sync

    private func syncPlatforms(now: CFTimeInterval) {
        var seen = Set<CGWindowID>()
        var skippedFullScreen = Set<CGWindowID>()
        var currentRects: [(rect: CGRect, z: Int)] = []

        for w in WindowTracker.shared.windows {
            let lr = space.toLocal(w.bounds)
            guard lr.maxX > 0, lr.minX < CGFloat(width),
                  lr.maxY > 0, lr.minY < CGFloat(height) else { continue }

            // Every on-screen window is an occluder, including ones that are too
            // big to carry a cap. Without this a maximised foreground window
            // would not hide the caps of the windows behind it.
            currentRects.append((lr, w.zIndex))

            // A window that covers the whole display *including the menu bar*
            // is treated as full-screen content and gets no cap. A normal
            // maximised window starts below the menu bar and should still
            // catch snow on its top edge.
            let coversMenuBar = lr.minY <= 1
            let fillsScreen = lr.width >= CGFloat(width) - 8
                && lr.height >= CGFloat(height) - 8
            if coversMenuBar && fillsScreen {
                seen.insert(w.id)
                skippedFullScreen.insert(w.id)
                continue
            }

            // Windows have rounded top corners. Keep the cap on the flat part of
            // the edge so it doesn't appear to float past the corners. Use the
            // window's true coordinates (not clamped to the display) so the cap
            // stays aligned while the window is dragged partly off-screen.
            let cornerInset: Float = w.isDock ? 4 : 8
            let x0 = Float(lr.minX) + cornerInset
            let x1 = Float(lr.maxX) - cornerInset
            let wWidth = x1 - x0
            guard wWidth > 30 else { continue }

            seen.insert(w.id)
            let edgeY = Float(lr.minY)

            if let p = platforms[w.id] {
                if now < w.shakeUntil && p.lastShed < w.shakeUntil {
                    shed(p, power: 1.0)
                    p.lastShed = w.shakeUntil
                }
                // The height profile is stored relative to the platform's own
                // left edge, so moving the platform carries the cap rigidly with
                // the window. Shifting the columns as well would move it twice.

                p.x0 = x0
                p.edgeY = edgeY
                p.zIndex = w.zIndex
                p.lastX0 = x0
                p.lastEdgeY = edgeY
                p.setWidth(wWidth)
                // A window flush with the menu bar has almost no headroom.
                // Keep the physical cap within the drawable region so falling
                // flakes land on the visible pile instead of hovering above it.
                let cap = max(4, p.edgeY - Float(space.topInset) + 8)
                p.maxHeight = min(Platform.defaultMaxHeight, cap)
                p.renderCap = p.maxHeight
            } else {
                let p = Platform(id: w.id, layer: .front, x0: x0,
                                 edgeY: edgeY, width: wWidth,
                                 zIndex: w.zIndex, isDock: w.isDock)
                platforms[w.id] = p
            }
        }

        // The Dock strip acts as a platform too, drawn on the front layer so the
        // snow sits on top of the pill instead of behind it.
        let dockID = dockPlatformID
        if let dock = DockGeometry.strip(for: space) {
            // Keep the cap off the pill's very rounded ends.
            let inset: Float = 4
            let dw = Float(dock.width) - inset * 2
            let dx0 = Float(dock.x0) + inset
            let dEdge = Float(dock.edgeY)
            if dw > 40 {
                seen.insert(dockID)
                if let p = platforms[dockID] {
                    p.x0 = dx0
                    p.edgeY = dEdge
                    p.lastX0 = dx0
                    p.lastEdgeY = dEdge
                    p.setWidth(dw)
                } else {
                    platforms[dockID] = Platform(id: dockID, layer: .front, x0: dx0,
                                                 edgeY: dEdge, width: dw,
                                                 zIndex: -1, isDock: true)
                }
                // The longer the app runs, the taller the Dock bank is allowed
                // to get. It keeps growing until it overflows off the ends.
                platforms[dockID]?.maxHeight = min(90, 36 + time * 0.025)
            }
        }

        // Desktop icons (requires Accessibility). Each icon's platform uses the
        // real artwork silhouette: a folder gets its tab, a document a narrow
        // page, an image its preview shape.
        IconTracker.shared.refreshIfNeeded(now: now)
        var iconsSeen = Set<String>()
        for icon in IconTracker.shared.icons {
            let lr = space.toLocal(icon.rect)
            guard lr.maxX > 0, lr.minX < CGFloat(width),
                  lr.maxY > 0, lr.minY < CGFloat(height) else { continue }

            let n = icon.profile.count
            guard n >= 4 else { continue }
            let w = Float(n) * Platform.cell
            let x0 = Float(lr.minX + icon.xOffset)
            let edgeY = Float(lr.minY)

            iconsSeen.insert(icon.id)
            let id = iconID(for: icon.id)

            if let p = platforms[id] {
                p.x0 = x0
                p.edgeY = edgeY
                p.setWidth(w)
            } else {
                platforms[id] = Platform(id: id, layer: .back, x0: x0, edgeY: edgeY,
                                         width: w, zIndex: 20_000, isDock: false)
            }
            guard let p = platforms[id] else { continue }

            var offsets = [Float](repeating: 0, count: p.heights.count)
            for i in 0..<min(offsets.count, n) {
                offsets[i] = icon.profile[i]
            }
            p.baseOffsets = offsets
            p.isIcon = true

            // Enough room for a proper snow bank, but not so much that it
            // buries the icon in the row above or runs into the menu bar.
            let topBase = edgeY + (icon.profile.min() ?? 0)
            let headroom = topBase - Float(space.topInset) + 3
            p.maxHeight = min(iconMaxHeight, max(6, headroom))
            p.renderCap = p.maxHeight + 1
            seen.insert(id)
        }
        if iconIDs.count != iconsSeen.count {
            iconIDs = iconIDs.filter { iconsSeen.contains($0.key) }
        }

        for (id, _) in platforms where !seen.contains(id) {
            // Remove silently. Shedding here made a burst of snow flash across
            // the screen when the Dock disappeared during a Space transition.
            platforms.removeValue(forKey: id)
        }
        // Drop caps on windows that just became full-screen, silently.
        for id in skippedFullScreen {
            platforms.removeValue(forKey: id)
        }

        updateOcclusion(rects: currentRects)
    }

    private func iconID(for title: String) -> CGWindowID {
        if let id = iconIDs[title] { return id }
        let id = nextIconID
        nextIconID += 1
        iconIDs[title] = id
        return id
    }

    /// A drift sitting on a window should not be drawn over a window that is
    /// in front of it. Sample just above each column and clip it.
    private func updateOcclusion(rects: [(rect: CGRect, z: Int)]) {
        let cell = Platform.cell
        for p in platforms.values {
            let n = p.heights.count
            if p.occluded.count != n {
                p.occluded = [Bool](repeating: false, count: n)
            }
            for i in 0..<n {
                let x = p.x0 + (Float(i) + 0.5) * cell
                let y = p.edgeY - 1.5
                var occ = false
                for r in rects where r.z < p.zIndex {
                    if r.rect.minX <= CGFloat(x), r.rect.maxX >= CGFloat(x),
                       r.rect.minY <= CGFloat(y), r.rect.maxY >= CGFloat(y) {
                        occ = true
                        break
                    }
                }
                p.occluded[i] = occ
            }
        }
    }

    // MARK: - Shedding

    private func shed(_ p: Platform, power: Float) {
        var i = 0
        while i < p.heights.count {
            let h = p.heights[i]
            if h > 0.4 {
                let x = p.x0 + (Float(i) + 0.5) * Platform.cell
                let y = surfaceY(p, x: x)
                // Break the slab into grains. Two per sampled column is enough
                // to read as a shower without turning the shake into a solid
                // wall of white.
                for _ in 0..<2 {
                    spawnGrain(x: x + Float.random(in: -2...2),
                               y: y + Float.random(in: -1...1),
                               vx: Float.random(in: -15...15) * power,
                               vy: Float.random(in: -35...(-5)) * power,
                               mass: min(3.5, h) * 0.5,
                               near: p.layer == .front,
                               ignoreID: p.id)
                }
            }
            i += 10
        }
        for j in p.heights.indices { p.heights[j] = 0 }
        p.spillLeft = 0
        p.spillRight = 0
    }

    /// One falling sand grain. Grains are deliberately tiny: a stream of them
    /// reads as loose snow sliding off an edge, not as a ball dropping.
    private func spawnGrain(x: Float, y: Float, vx: Float, vy: Float,
                            mass: Float, near: Bool, ignoreID: CGWindowID? = nil) {
        guard !grains.isEmpty else { return }
        grainRecycleIndex = (grainRecycleIndex + 1) % grains.count
        var g = grains[grainRecycleIndex]
        g.x = x
        g.y = y
        g.vx = vx
        g.vy = vy
        g.isClump = true
        g.mass = max(0.01, mass)
        g.size = Float.random(in: 0.8...1.9)
        g.alpha = Float.random(in: 0.72...1.0)
        g.near = near
        g.enabled = true
        g.spin = Float.random(in: -9...9)
        g.seed = Float.random(in: 0..<1)
        g.rot = Float.random(in: 0..<6.283)
        g.drift = 0
        g.windFactor = 0
        g.terminal = 340
        g.ignoreID = ignoreID
        grains[grainRecycleIndex] = g
    }

    /// Advance the loose grains. They are ballistic and land on the first
    /// platform they cross, depositing their mass into that drift.
    private func updateGrains(dt: Float, gravity: Float) {
        for i in grains.indices {
            var g = grains[i]
            guard g.enabled else { continue }

            let prevY = g.y
            g.vy += gravity * 2.2 * dt
            if g.vy > 340 { g.vy = 340 }
            // A very slight flutter keeps the trickle from looking like a
            // perfectly straight laser line, but it is far too small to read
            // as the snow being thrown sideways.
            g.x += (g.vx + sin(g.seed * 6.283 + g.y * 0.025) * 5) * dt
            g.y += g.vy * dt
            g.rot += g.spin * dt
            g.vx *= max(0, 1 - dt * 0.9)

            if g.x < -30 || g.x > width + 30 || g.y > height + 40 {
                g.enabled = false
                grains[i] = g
                continue
            }

            var landed = false
            if g.near {
                if let p = firstPlatformCrossed(from: prevY, to: g.y, x: g.x,
                                               layer: .front, ignoring: g.ignoreID) {
                    p.deposit(g.x, g.mass)
                    landed = true
                } else {
                    let surf = surfaceY(ground, x: g.x)
                    if g.y >= surf {
                        ground.deposit(g.x, g.mass)
                        landed = true
                    }
                }
            } else {
                // A grain falling behind a window still lands on it, then on a
                // desktop icon, then on the ground.
                if let p = firstPlatformCrossed(from: prevY, to: g.y, x: g.x,
                                               layer: .front, ignoring: g.ignoreID) {
                    p.deposit(g.x, g.mass)
                    landed = true
                } else if let p = firstPlatformCrossed(from: prevY, to: g.y, x: g.x,
                                                      layer: .back, ignoring: g.ignoreID) {
                    p.deposit(g.x, g.mass)
                    landed = true
                } else {
                    let surf = surfaceY(ground, x: g.x)
                    if g.y >= surf {
                        ground.deposit(g.x, g.mass)
                        landed = true
                    }
                }
            }
            if landed { g.enabled = false }
            grains[i] = g
        }
    }

    /// Snow that has just slid off an edge: starts with a small outward nudge
    /// and then falls normally.
    private func spawnFalling(x: Float, y: Float, vx: Float, vy: Float) {
        guard !flakes.isEmpty else { return }
        recycleIndex = (recycleIndex + 1) % flakes.count
        var f = flakes[recycleIndex]
        f.x = x
        f.y = y
        f.vx = vx + Float.random(in: -6...6)
        f.vy = vy + Float.random(in: 0...12)
        f.near = true
        f.size = Float.random(in: 1.2...2.6)
        f.alpha = Float.random(in: 0.5...0.95)
        f.spin = Float.random(in: -5...5)
        f.seed = Float.random(in: 0..<1)
        flakes[recycleIndex] = f
    }

    // MARK: - Cursor

    /// The cursor shoves the drift in discrete bites instead of stirring it like
    /// a fluid. Snow only moves when the cursor has travelled far enough, and
    /// each shove moves a small block into the next column. The result is a
    /// powder that piles up in front of the cursor and spills in chunks.
    private func ploughWithCursor(dt: Float) {
        guard cursorVisible else {
            hasLastCursor = false
            hasLastPlough = false
            return
        }

        let cx = Float(cursor.x)
        let cy = Float(cursor.y)

        var vx: Float = 0
        if hasLastCursor {
            vx = (cx - Float(lastCursor.x)) / max(dt, 0.001)
        }
        lastCursor = cursor
        hasLastCursor = true

        if !hasLastPlough {
            lastPloughX = cx
            hasLastPlough = true
            return
        }

        let dx = cx - lastPloughX
        guard abs(dx) >= 2.0, abs(vx) > 30 else { return }
        lastPloughX = cx

        let dir: Float = dx > 0 ? 1 : -1
        let speed = min(abs(vx), 700)
        let down = ScreenGeometry.isMouseDown
        let radius: Float = down ? 24 : 15
        // One small bite of snow per shove. It moves into the next column only.
        let bite = min(1.8, abs(dx) * 0.35)
        guard bite > 0.02 else { return }

        for p in allPlatforms() {
            guard cx > p.x0 - radius, cx < p.x0 + p.width + radius else { continue }
            let n = p.heights.count
            let i0 = max(0, Int((cx - radius - p.x0) / Platform.cell))
            let i1 = min(n - 1, Int((cx + radius - p.x0) / Platform.cell))
            guard i0 <= i1 else { continue }

            // Push from the leading edge inward so a column cannot be moved
            // twice in one shove.
            let indices: StrideThrough<Int> = dir > 0
                ? stride(from: i1, through: i0, by: -1)
                : stride(from: i0, through: i1, by: 1)

            for i in indices {
                let colX = p.x0 + (Float(i) + 0.5) * Platform.cell
                let h = p.heights[i]
                if h < 0.15 { continue }
                let surface = surfaceY(p, x: colX)
                // Only from above the window's top edge: otherwise grabbing the
                // title bar to drag the window would plough the cap. Icons have
                // their surface lower than the top of their 64 pt cell.
                guard cy > surface - 18 && cy < p.edgeY + p.maxBaseOffset + 2 else { continue }

                let d = abs(colX - cx)
                guard d < radius else { continue }
                let t = d / radius
                // Push mostly the snow in front of the cursor. Snow behind
                // the blade should stay put, like powder rather than a liquid.
                let lead = (colX - cx) * dir
                let w = (1 - t * t) * (lead > 0 ? 1.0 : 0.25)
                let amount = min(h, bite * w)
                guard amount > 0.001 else { continue }

                let j = i + (dir > 0 ? 1 : -1)
                if j >= 0 && j < n {
                    // Powder resists being shoved into an already taller bank.
                    if p.heights[j] < p.maxHeight &&
                       (p.heights[j] < h + 1.2 || speed > 320) {
                        p.heights[i] -= amount
                        p.heights[j] += amount
                    }
                } else {
                    p.heights[i] -= amount
                    if dir > 0 { p.spillRight += amount } else { p.spillLeft += amount }
                }
            }
        }
    }

    private func allPlatforms() -> [Platform] {
        var all: [Platform] = [ground]
        all.append(contentsOf: platforms.values)
        return all
    }

    // MARK: - Surface flow

    private func updateSurface(_ p: Platform, dt: Float, now: CFTimeInterval) {
        relax(p)
        shedEdges(p, dt: dt, now: now)
        shedEdgeFlakes(p, now: now)
    }

    /// Snow over the edge is collected as spill mass. It is released later in
    /// small clusters, not as a continuous stream.
    private func shedEdges(_ p: Platform, dt: Float, now: CFTimeInterval) {
        let n = p.heights.count
        guard n > 8 else { return }

        if p.isIcon {
            shedIconAvalanche(p, now: now)
            return
        }

        let threshold = p.maxHeight * p.shedFraction
        let rate = dt * 3.0

        func spill(at idx: Int, side: Float) {
            let h = p.heights[idx]
            guard h > threshold else { return }
            let amount = min(h - threshold, rate)
            p.heights[idx] -= amount
            if side < 0 {
                p.spillLeft += amount
            } else {
                p.spillRight += amount
            }
        }

        spill(at: 0, side: -1)
        spill(at: 1, side: -1)
        spill(at: n - 2, side: 1)
        spill(at: n - 1, side: 1)
    }

    /// A lip that has collected too much snow releases it as a scattered
    /// trickle: one flake at a time, from a random point across the last few
    /// columns. The random position and cadence keep it from looking like a tap.
    private func shedEdgeFlakes(_ p: Platform, now: CFTimeInterval) {
        let total = p.spillLeft + p.spillRight
        guard total > 0.05, now >= p.nextEdgeShed else { return }

        let side: Float = p.spillRight >= p.spillLeft ? 1 : -1
        let available = side > 0 ? p.spillRight : p.spillLeft
        guard available > 0.03 else { return }

        // Pick a random point just outside the lip, not the same corner every
        // time. The flakes must start beyond the cap so they fall past it
        // instead of sinking through the snow.
        let edgeWidth = min(12, max(4, p.width * 0.08))
        let out = Float.random(in: 0...edgeWidth)
        let x = side < 0 ? p.x0 - out : p.x0 + p.width + out
        let edgeX = side < 0 ? p.x0 + 1 : p.x0 + p.width - 1
        let y = surfaceY(p, x: edgeX) - Float.random(in: 0...2)
        let mass = min(available, 0.5)

        spawnGrain(x: x + Float.random(in: -2...2),
                   y: y,
                   vx: side * Float.random(in: 0...6) + Float.random(in: -3...3),
                   vy: Float.random(in: 0...10),
                   mass: mass,
                   near: p.layer == .front,
                   ignoreID: p.id)

        if side > 0 {
            p.spillRight = max(0, p.spillRight - mass)
        } else {
            p.spillLeft = max(0, p.spillLeft - mass)
        }

        // Irregular cadence, a little faster when more snow is waiting.
        let base: Double = total > 1.5 ? 0.05 : (total > 0.5 ? 0.09 : 0.14)
        p.nextEdgeShed = now + Double.random(in: base...(base * 1.9))
    }

    /// Desktop piles stay low by losing a small wedge off one side every so
    /// often. Timing, side and size are random, so a file never builds a tower
    /// and never looks like it is shedding on a schedule.
    private func shedIconAvalanche(_ p: Platform, now: CFTimeInterval) {
        guard now >= p.nextSpill else { return }
        guard now >= nextAmbientClump else {
            // Another platform is shedding right now. Slack off for a moment
            // rather than queueing a burst of chunks across all the icons.
            p.nextSpill = now + Double.random(in: 2.5...6.0)
            return
        }

        let n = p.heights.count
        guard n >= 6 else { return }

        // Roll-offs begin around halfway up the allowed pile. The file keeps a
        // modest cap instead of climbing to the full maxHeight first.
        let threshold = p.maxHeight * Float.random(in: 0.45...0.60)
        let probe = max(2, min(6, n / 3))
        var leftPeak: Float = 0
        var rightPeak: Float = 0
        for i in 0..<probe {
            leftPeak = max(leftPeak, p.heights[i])
            rightPeak = max(rightPeak, p.heights[n - 1 - i])
        }
        guard max(leftPeak, rightPeak) >= threshold else {
            // Not deep enough yet; look again shortly.
            p.nextSpill = now + Double.random(in: 3...6)
            return
        }

        // Usually roll off the heavier flank, but sometimes the light side.
        let heavySide: Float = leftPeak >= rightPeak ? -1 : 1
        let side: Float = Float.random(in: 0..<1) < 0.7 ? heavySide : -heavySide
        p.nextSpill = now + Double.random(in: 25...55)
        nextAmbientClump = now + 6.0

        // A small tapered slice leaves the rest of the drift in place.
        let span = max(2, min(6, n / 5))
        let drop = p.maxHeight * Float.random(in: 0.22...0.34)
        var fallen: Float = 0
        for k in 0..<span {
            let idx = side < 0 ? k : n - 1 - k
            let taper = 1 - Float(k) / Float(span)
            let amount = min(p.heights[idx], drop * taper)
            p.heights[idx] -= amount
            fallen += amount
        }

        let mass = min(2.2, max(0.9, fallen * 0.05))
        if side < 0 {
            p.spillLeft += mass
        } else {
            p.spillRight += mass
        }
        p.nextEdgeShed = min(p.nextEdgeShed, now)
    }

    // MARK: - Relaxation

    /// Snow slumps sideways until it reaches an angle of repose. Powder holds a
    /// steeper edge than a liquid, so it only gives way in small chunks.
    private func relax(_ p: Platform) {
        let n = p.heights.count
        guard n > 2 else { return }
        let slope: Float = 2.2

        for _ in 0..<1 {
            for i in 0..<(n - 1) {
                let a = p.heights[i]
                let b = p.heights[i + 1]
                if a < 0.05 && b < 0.05 { continue }
                let d = a - b
                if d > slope {
                    let m = (d - slope) * 0.30
                    p.heights[i] = a - m
                    p.heights[i + 1] = b + m
                } else if d < -slope {
                    let m = (-d - slope) * 0.30
                    p.heights[i] = a + m
                    p.heights[i + 1] = b - m
                }
            }
        }

        for i in 0..<n {
            if p.heights[i] < 0.02 { p.heights[i] = 0 }
            else if p.heights[i] > p.maxHeight { p.heights[i] = p.maxHeight }
        }
    }

    // MARK: - Vertex building

    private func buildVertices() {
        backFlakes.removeAll(keepingCapacity: true)
        frontFlakes.removeAll(keepingCapacity: true)
        backDrift.removeAll(keepingCapacity: true)
        frontDrift.removeAll(keepingCapacity: true)

        for f in flakes {
            guard f.enabled, f.x > -8, f.x < width + 8 else { continue }
            let inst = FlakeInstance(
                pos: SIMD2<Float>(f.x, f.y),
                size: f.size,
                alpha: f.alpha,
                rot: f.rot,
                seed: f.seed
            )
            if f.near { frontFlakes.append(inst) } else { backFlakes.append(inst) }
        }

        for g in grains {
            guard g.enabled, g.x > -8, g.x < width + 8 else { continue }
            let inst = FlakeInstance(
                pos: SIMD2<Float>(g.x, g.y),
                size: g.size,
                alpha: g.alpha,
                rot: g.rot,
                seed: g.seed
            )
            if g.near { frontFlakes.append(inst) } else { backFlakes.append(inst) }
        }

        buildDrift(ground, into: &backDrift)
        for p in platforms.values {
            if p.layer == .front {
                buildDrift(p, into: &frontDrift)
            } else {
                buildDrift(p, into: &backDrift)
            }
        }
    }

    private func buildDrift(_ p: Platform, into out: inout [DriftVertex]) {
        let n = p.heights.count
        guard n > 1 else { return }
        let cell = Platform.cell

        var peak: Float = 0
        for h in p.heights where h > peak { peak = h }
        guard peak > 0.2 else { return }

        // If the drift would grow into the menu bar, shrink it proportionally
        // instead of clipping it, so it keeps its shape.
        let scale: Float = peak > p.renderCap ? max(0.05, p.renderCap / peak) : 1

        for i in 0..<(n - 1) {
            let h0 = p.heights[i]
            let h1 = p.heights[i + 1]
            if h0 < 0.12 && h1 < 0.12 { continue }

            if p.layer == .front {
                if p.occluded.count == n && (p.occluded[i] || p.occluded[i + 1]) { continue }
            }

            // Smooth the profile so the columns don't read as a staircase.
            let hm2 = i >= 2 ? p.heights[i - 2] : h0
            let hm1 = i >= 1 ? p.heights[i - 1] : h0
            let hp1 = i + 2 < n ? p.heights[i + 2] : h1
            let hp2 = i + 3 < n ? p.heights[i + 3] : h1
            let sm0 = (hm2 + 4 * hm1 + 6 * h0 + 4 * h1 + hp1) / 16
            let sm1 = (hm1 + 4 * h0 + 6 * h1 + 4 * hp1 + hp2) / 16

            // Curve the very end a little so it doesn't end in a razor cut;
            // anything thicker spills off as falling particles.
            let edgeCols = p.isDock ? 1.5 : min(3, Float(n) * 0.2)
            let dEdge = Float(min(i, n - 2 - i))
            var fade: Float = 1
            if dEdge < edgeCols {
                let t = max(0, dEdge / edgeCols)
                fade = t * t * (3 - 2 * t)
            }

            // Low-frequency roughness keeps a saturated cap from going flat.
            let r0 = i < p.rough.count ? p.rough[i] : 1
            let r1 = i + 1 < p.rough.count ? p.rough[i + 1] : 1

            let s0 = sm0 * scale * fade * r0
            let s1 = sm1 * scale * fade * r1

            let xa = p.x0 + Float(i) * cell
            let xb = xa + cell
            let baseA = p.edgeY + (i < p.baseOffsets.count ? p.baseOffsets[i] : 0)
            let baseB = p.edgeY + (i + 1 < p.baseOffsets.count ? p.baseOffsets[i + 1] : 0)
            let ya = baseA - s0
            let yb = baseB - s1
            // Thin dusting should fade out rather than show as a hard segment.
            let alpha = min(1.0, max(s0, s1) * 1.6)

            // Body
            out.append(DriftVertex(pos: SIMD2<Float>(xa, baseA), par: 0.0, alpha: alpha))
            out.append(DriftVertex(pos: SIMD2<Float>(xa, ya),    par: 1.0, alpha: alpha))
            out.append(DriftVertex(pos: SIMD2<Float>(xb, yb),    par: 1.0, alpha: alpha))

            out.append(DriftVertex(pos: SIMD2<Float>(xa, baseA), par: 0.0, alpha: alpha))
            out.append(DriftVertex(pos: SIMD2<Float>(xb, yb),    par: 1.0, alpha: alpha))
            out.append(DriftVertex(pos: SIMD2<Float>(xb, baseB), par: 0.0, alpha: alpha))

            // Lit crest along the top surface, only where there is a real cap.
            if min(s0, s1) > 0.45 {
                out.append(DriftVertex(pos: SIMD2<Float>(xa, ya),        par: 1.12, alpha: alpha))
                out.append(DriftVertex(pos: SIMD2<Float>(xa, ya - 1.0),  par: 1.25, alpha: alpha * 0.9))
                out.append(DriftVertex(pos: SIMD2<Float>(xb, yb - 1.0),  par: 1.25, alpha: alpha * 0.9))

                out.append(DriftVertex(pos: SIMD2<Float>(xa, ya),        par: 1.12, alpha: alpha))
                out.append(DriftVertex(pos: SIMD2<Float>(xb, yb - 1.0),  par: 1.25, alpha: alpha * 0.9))
                out.append(DriftVertex(pos: SIMD2<Float>(xb, yb),        par: 1.12, alpha: alpha))
            }
        }
    }
}
