import AppKit
import QuartzCore
import simd

/// One leaf sprite handed to Metal.
struct LeafInstance {
    var pos: SIMD2<Float>
    var size: Float
    var angle: Float
    var alpha: Float
    var shape: Float
    var flip: Float
    var tint: SIMD4<Float>
}

private struct Leaf {
    var pos = SIMD2<Float>(0, 0)
    var prevPos = SIMD2<Float>(0, 0)
    var vel = SIMD2<Float>(0, 0)
    var radius: Float = 8
    var size: Float = 16
    var angle: Float = 0
    var angVel: Float = 0
    var shape: Float = 0
    var flip: Float = 0
    var tint = SIMD4<Float>(1, 1, 1, 1)
    var layer: SnowLayer = .back
    var active = false
    var asleep = false
    var sleepTimer: Float = 0
    var group: UInt64 = 0
    var support: UInt64 = 0
    var settledAt: Float = 0
    var ambient = false
    var fading = false
    var alpha: Float = 1
    var phase: Float = 0
    var drift: Float = 0
    var flutter: Float = 0
    var terminal: Float = 45
    /// While these are in the future the leaf ignores window supports/pushes.
    /// Used to let leaves peel off a moving window instead of sticking to it.
    var noSupportUntil: Float = 0
    var noPushUntil: Float = 0
}

private struct LeafSurface {
    let id: UInt64
    var layer: SnowLayer
    var x0: Float
    var x1: Float
    var edgeY: Float
    var baseOffsets: [Float]
    var isDock: Bool
    var isIcon: Bool
    var bottomY: Float = 0
    var zIndex: Int = 0
    var vx: Float = 0
    var vy: Float = 0
    var lastUpdate: Float = 0

    var isWindow: Bool {
        !isDock && !isIcon && id != 0
    }

    var isMoving: Bool {
        guard isWindow else { return false }
        return vx * vx + vy * vy > 30 * 30
    }

    func surfaceY(_ x: Float) -> Float {
        let idx = Int((x - x0) / Platform.cell)
        guard idx >= 0 && idx < baseOffsets.count else { return edgeY }
        return edgeY + baseOffsets[idx]
    }
}

/// Autumn: every leaf is its own small body. Nothing is compressed into a
/// height field; leaves keep their shape, angle and individual pile position.
final class AutumnEngine: SeasonEngine {
    let space: ScreenSpace
    let width: Float
    let height: Float

    private(set) var backLeaves: [LeafInstance] = []
    private(set) var frontLeaves: [LeafInstance] = []

    private var leaves: [Leaf] = []
    private var surfaces: [UInt64: LeafSurface] = [:]
    private var iconIDs: [String: UInt64] = [:]
    private var nextIconID: UInt64 = 3_000_000

    private var density: SnowDensity
    private var time: Float = 0
    private var lastStep: CFTimeInterval = 0

    private var cursor = CGPoint.zero
    private var cursorVisible = false
    private var lastCursor = CGPoint.zero
    private var hasLastCursor = false
    private var cursorVX: Float = 0
    private var cursorVY: Float = 0

    private var windBase: Float = 0
    private var freezeUntil: Float = 0
    private var resetWindowSurfaces = false
    private var neverDisappear = false
    private var pendingSpawns = 0
    private var showerSpawnAccumulator: Float = 0
    private var frameTimeAvg: Float = 1.0 / 60.0
    private var pileSaturated = false
    /// Shower mode has no leaf cap at all. Other modes keep the original cap.
    private var maxLeafCount: Int {
        density == .shower ? Int.max : 1400
    }
    private var ambientCount = 0
    private var targetAmbient = 0
    private var initialSettled = 0
    private var settledCount = 0

    private let groundID: UInt64 = 0
    private let dockID: UInt64 = 1

    private var cellSize: Float = 48
    private var bucketW: Int = 1
    private var buckets: [Int: [Int]] = [:]

    private let gravityMagnitude: Float = 40
    private var gravityDir = SIMD2<Float>(0, 1)
    private var lastWakeGravity = SIMD2<Float>(0, 1)
    private let shapeCount: Float = 8
    private let palette: [SIMD4<Float>] = [
        SIMD4(0.82, 0.34, 0.08, 1), // burnt orange
        SIMD4(0.90, 0.52, 0.10, 1), // amber
        SIMD4(0.95, 0.72, 0.12, 1), // gold
        SIMD4(0.72, 0.20, 0.10, 1), // rust red
        SIMD4(0.62, 0.16, 0.08, 1), // deep red
        SIMD4(0.55, 0.32, 0.10, 1), // brown
        SIMD4(0.86, 0.42, 0.14, 1), // orange
        SIMD4(0.78, 0.60, 0.14, 1)  // yellow ochre
    ]

    init(space: ScreenSpace, density: SnowDensity) {
        self.space = space
        self.width = Float(space.size.width)
        self.height = Float(space.size.height)
        self.density = density
        self.bucketW = max(1, Int(ceil(self.width / self.cellSize)))
        self.surfaces[groundID] = LeafSurface(
            id: groundID, layer: .back, x0: 0, x1: self.width,
            edgeY: self.height, baseOffsets: [], isDock: false, isIcon: false
        )
        rebuildLeaves()
    }

    // MARK: - SeasonEngine

    func setDensity(_ d: SnowDensity) {
        guard d != density else { return }
        density = d
        rebuildLeaves()
    }

    func clear() {
        rebuildLeaves()
    }

    func setNeverDisappear(_ value: Bool) {
        neverDisappear = value
    }

    func stepIfNeeded(_ now: CFTimeInterval) {
        let dt = now - lastStep
        guard dt >= 1.0 / 70.0 else { return }
        lastStep = now
        step(min(Float(dt), 1.0 / 20.0), now: now)
    }

    // MARK: - Setup

    private func rebuildLeaves() {
        let count = density.leafCount
        leaves = [Leaf](repeating: Leaf(), count: count)
        if density == .shower {
            // A shower is all air: every initial leaf is falling.
            ambientCount = count
            initialSettled = 0
        } else {
            ambientCount = max(24, Int(Float(count) * 0.30))
            initialSettled = max(10, Int(Float(count) * 0.10))
        }
        targetAmbient = ambientCount
        settledCount = 0
        backLeaves.removeAll(keepingCapacity: true)
        frontLeaves.removeAll(keepingCapacity: true)
        pendingSpawns = 0
        pileSaturated = false

        for _ in 0..<min(initialSettled, count) {
            guard let i = firstInactiveIndex() else { break }
            spawnSettledGround(&leaves[i])
            settledCount += 1
        }
        for _ in 0..<min(ambientCount, count - settledCount) {
            guard let i = firstInactiveIndex() else { break }
            spawnAmbient(&leaves[i], spread: true)
        }
    }

    private func firstInactiveIndex() -> Int? {
        for i in leaves.indices where !leaves[i].active { return i }
        return nil
    }

    private func spawnSettledGround(_ leaf: inout Leaf) {
        resetCommon(&leaf)
        leaf.size = Float.random(in: 7...13)
        leaf.radius = leaf.size * 0.70
        leaf.pos = SIMD2(Float.random(in: leaf.radius...(width - leaf.radius)),
                         height - leaf.radius - Float.random(in: 0...4))
        leaf.prevPos = leaf.pos
        leaf.layer = .back
        leaf.asleep = true
        leaf.ambient = false
        leaf.group = groundID
        leaf.support = groundID
        leaf.settledAt = 0
        leaf.active = true
    }

    private func spawnAmbient(_ leaf: inout Leaf, spread: Bool = false) {
        resetCommon(&leaf)
        leaf.size = Float.random(in: 7...13)
        leaf.radius = leaf.size * 0.70
        leaf.pos.x = Float.random(in: -20...(width + 20))
        let fallingUp = gravityDir.y < -0.25
        if fallingUp {
            leaf.pos.y = spread
                ? height + Float.random(in: 10...max(20, height * 0.85))
                : height + Float.random(in: 10...70)
            leaf.vel = SIMD2(
                Float.random(in: -8...8) + gravityDir.x * 30,
                -Float.random(in: 20...50)
            )
        } else {
            leaf.pos.y = spread
                ? -Float.random(in: 10...max(20, height * 0.85))
                : -Float.random(in: 10...70)
            leaf.vel = SIMD2(
                Float.random(in: -8...8) + gravityDir.x * 30,
                Float.random(in: 20...50)
            )
        }
        leaf.prevPos = leaf.pos
        leaf.terminal = Float.random(in: 55...105)
        leaf.flutter = Float.random(in: 3...9)
        leaf.layer = Float.random(in: 0..<1) < 0.65 ? .front : .back
        leaf.ambient = true
        leaf.active = true
        leaf.asleep = false
        leaf.alpha = 1
    }

    private func resetCommon(_ leaf: inout Leaf) {
        leaf = Leaf()
        leaf.angle = Float.random(in: 0..<6.283)
        leaf.angVel = Float.random(in: -0.55...0.55)
        leaf.shape = Float(Int.random(in: 0..<8))
        leaf.flip = Float.random(in: 0..<1) < 0.5 ? 0 : 1
        leaf.tint = palette.randomElement() ?? palette[0]
        leaf.phase = Float.random(in: 0..<6.283)
        leaf.drift = Float.random(in: -6...6)
        leaf.alpha = Float.random(in: 0.88...1.0)
    }

    // MARK: - Step

    private func step(_ dt: Float, now: CFTimeInterval) {
        time += dt
        updateCursor()

        SpaceMonitor.shared.refreshIfNeeded(now: now)
        if SpaceMonitor.shared.isFullScreen {
            clearRender()
            return
        }
        WindowTracker.shared.refreshIfNeeded(now: now)
        if WindowTracker.shared.isMissionControl {
            clearRender()
            return
        }
        if WindowTracker.shared.coversDisplay(space,
                                              width: CGFloat(width),
                                              height: CGFloat(height)) {
            clearRender()
            return
        }

        // A three-finger Space swipe slides every window sideways. Freeze the
        // leaf simulation during that gesture so the whole desktop doesn't
        // drag its leaves along with it.
        if SpaceMonitor.shared.isSpaceTransitioning {
            freezeUntil = max(freezeUntil, time + 0.40)
            resetWindowSurfaces = true
        }
        if !ScreenGeometry.isMouseDown,
           abs(cursorVX) + abs(cursorVY) < 35 {
            let normal = WindowTracker.shared.windows.filter { !$0.isDock }
            var moving = 0
            var fastest: Float = 0
            for w in normal {
                let speed = max(abs(Float(w.velocity.x)), abs(Float(w.velocity.y)))
                if speed > 120 { moving += 1 }
                fastest = max(fastest, speed)
            }
            if moving >= 2 || (normal.count == 1 && fastest > 250) {
                freezeUntil = max(freezeUntil, time + 0.40)
                resetWindowSurfaces = true
            }
        }
        if time < freezeUntil {
            return
        }
        if resetWindowSurfaces {
            resetWindowSurfaces = false
            for (id, surface) in surfaces where surface.isWindow {
                wakeGroup(id)
                surfaces.removeValue(forKey: id)
            }
        }

        syncSurfaces(now: now)
        updateWind()
        updateLeaves(dt: dt)
        buildInstances()
    }

    private func clearRender() {
        backLeaves.removeAll(keepingCapacity: true)
        frontLeaves.removeAll(keepingCapacity: true)
    }

    private func updateCursor() {
        cursor = ScreenGeometry.cursorLocal(in: space)
        cursorVisible = cursor.x >= -2 && cursor.x <= CGFloat(width) + 2
            && cursor.y >= -2 && cursor.y <= CGFloat(height) + 2
        guard cursorVisible else {
            hasLastCursor = false
            cursorVX = 0
            cursorVY = 0
            return
        }
        var vx: Float = 0
        var vy: Float = 0
        if hasLastCursor {
            vx = (Float(cursor.x) - Float(lastCursor.x)) / 0.016
            vy = (Float(cursor.y) - Float(lastCursor.y)) / 0.016
        }
        lastCursor = cursor
        hasLastCursor = true
        cursorVX = vx
        cursorVY = vy
    }

    private func updateWind() {
        let gust = 8 * pow(max(0, sin(time * 0.13 + 0.5)), 5)
        windBase = 4 * sin(time * 0.09)
                 + 3 * sin(time * 0.23 + 1.1)
                 + gust
    }

    // MARK: - Surfaces

    private func syncSurfaces(now: CFTimeInterval) {
        var seen = Set<UInt64>()
        let dockHidden = NSApplication.shared.currentSystemPresentationOptions.contains(.hideDock)
        let spaceChanging = SpaceMonitor.shared.isSpaceTransitioning

        for w in WindowTracker.shared.windows {
            let lr = space.toLocal(w.bounds)
            guard lr.maxX > 0, lr.minX < CGFloat(width),
                  lr.maxY > 0, lr.minY < CGFloat(height) else { continue }
            let coversMenuBar = lr.minY <= 1
            let fillsScreen = lr.width >= CGFloat(width) - 8
                && lr.height >= CGFloat(height) - 8
            if coversMenuBar && fillsScreen { continue }

            let inset: Float = 4
            let x0 = Float(lr.minX) + inset
            let x1 = Float(lr.maxX) - inset
            guard x1 - x0 > 30 else { continue }
            let id = UInt64(w.id)
            let edgeY = Float(lr.minY)

            // A window shrinking and moving down is being minimized. Wake its
            // leaves before the surface disappears so they fall.
            if let old = surfaces[id],
               (x1 - x0) < (old.x1 - old.x0) * 0.82,
               edgeY > old.edgeY + 14 {
                wakeGroup(id)
                surfaces.removeValue(forKey: id)
                continue
            }

            updateSurface(id: id, layer: .front, x0: x0, x1: x1,
                          edgeY: edgeY, baseOffsets: [],
                          isDock: false, isIcon: false,
                          bottomY: Float(lr.maxY), zIndex: w.zIndex, seen: &seen)
        }

        if !dockHidden && !spaceChanging, let dock = DockGeometry.strip(for: space) {
            let axFrame: (x: Float, x1: Float)? = {
                guard let ax = DockAX.pillFrame() else { return nil }
                let local = space.toLocal(CGRect(x: ax.x, y: 0,
                                                 width: ax.width, height: ax.height))
                guard local.minX > -40,
                      local.maxX < CGFloat(width) + 40 else { return nil }
                return (Float(local.minX) + 2, Float(local.maxX) - 2)
            }()
            let x0: Float
            let x1: Float
            if let axFrame {
                x0 = axFrame.x
                x1 = axFrame.x1
            } else {
                x0 = Float(dock.x0) + 12
                x1 = Float(dock.x0 + dock.width) - 12
            }
            if x1 - x0 > 40 {
                updateSurface(id: dockID, layer: .front, x0: x0, x1: x1,
                              edgeY: Float(dock.edgeY), baseOffsets: [],
                              isDock: true, isIcon: false, seen: &seen)
            }
        } else if surfaces[dockID] != nil {
            wakeGroup(dockID)
            surfaces.removeValue(forKey: dockID)
        }

        IconTracker.shared.refreshIfNeeded(now: now)
        for icon in IconTracker.shared.icons {
            let lr = space.toLocal(icon.rect)
            guard lr.maxX > 0, lr.minX < CGFloat(width),
                  lr.maxY > 0, lr.minY < CGFloat(height) else { continue }
            let id = iconSurfaceID(icon.id)
            let x0 = Float(lr.minX + icon.xOffset)
            let w = Float(icon.profile.count) * Platform.cell
            updateSurface(id: id, layer: .back, x0: x0, x1: x0 + w,
                          edgeY: Float(lr.minY), baseOffsets: icon.profile,
                          isDock: false, isIcon: true,
                          bottomY: Float(lr.maxY), seen: &seen)
        }

        updateSurface(id: groundID, layer: .back, x0: 0, x1: width,
                      edgeY: height, baseOffsets: [],
                      isDock: false, isIcon: false, seen: &seen)

        for (id, _) in surfaces where !seen.contains(id) {
            wakeGroup(id)
            surfaces.removeValue(forKey: id)
        }
    }

    private func iconSurfaceID(_ key: String) -> UInt64 {
        if let id = iconIDs[key] { return id }
        let id = nextIconID
        nextIconID += 1
        iconIDs[key] = id
        return id
    }

    private func updateSurface(id: UInt64, layer: SnowLayer, x0: Float, x1: Float,
                               edgeY: Float, baseOffsets: [Float],
                               isDock: Bool, isIcon: Bool,
                               bottomY: Float = 0, zIndex: Int = 0,
                               seen: inout Set<UInt64>) {
        seen.insert(id)
        if var s = surfaces[id] {
            let dx = x0 - s.x0
            let dy = edgeY - s.edgeY
            let dtS = max(1.0 / 240.0, time - s.lastUpdate)
            s.lastUpdate = time
            let rawVX = max(-4000, min(4000, dx / dtS))
            let rawVY = max(-4000, min(4000, dy / dtS))
            s.vx = s.vx * 0.55 + rawVX * 0.45
            s.vy = s.vy * 0.55 + rawVY * 0.45
            s.layer = layer
            s.x0 = x0
            s.x1 = x1
            s.edgeY = edgeY
            s.baseOffsets = baseOffsets
            s.isDock = isDock
            s.isIcon = isIcon
            s.bottomY = bottomY
            s.zIndex = zIndex
            surfaces[id] = s
            let moveThreshold: Float = isIcon ? 1.0 : 0.2
            if abs(dx) > moveThreshold || abs(dy) > moveThreshold {
                if isDock {
                    // The Dock magnifies under leaves; keep them riding it.
                    shiftLeaves(group: id, dx: dx, dy: dy)
                } else if id != groundID {
                    releaseLeaves(group: id, vx: s.vx, vy: s.vy)
                }
            }
        } else {
            surfaces[id] = LeafSurface(id: id, layer: layer, x0: x0, x1: x1,
                                       edgeY: edgeY, baseOffsets: baseOffsets,
                                       isDock: isDock, isIcon: isIcon,
                                       bottomY: bottomY, zIndex: zIndex,
                                       lastUpdate: time)
        }
    }

    /// A moving window should not carry its leaves. Let them lag in the air
    /// and peel off instead.
    private func releaseLeaves(group id: UInt64, vx: Float, vy: Float) {
        for i in leaves.indices where leaves[i].active && leaves[i].group == id {
            // If the window is stacked behind another one, let the leaf fall
            // behind that window instead of popping through it.
            if isCoveredByHigherWindow(leaves[i]) {
                leaves[i].layer = .back
            }
            leaves[i].asleep = false
            leaves[i].sleepTimer = 0
            leaves[i].group = 0
            leaves[i].support = 0
            // Air resistance: the leaf is left behind as the window slides
            // out from under it. The tiny lift helps it break contact.
            leaves[i].vel.x -= vx * 0.055
            leaves[i].vel.y -= vy * 0.055
            leaves[i].vel.x += Float.random(in: -7...7)
            leaves[i].vel.y -= Float.random(in: 1...5)
            leaves[i].noSupportUntil = time + 0.40
            leaves[i].noPushUntil = time + 0.22
        }
    }

    private func shiftLeaves(group id: UInt64, dx: Float, dy: Float) {
        for i in leaves.indices where leaves[i].active && leaves[i].group == id {
            leaves[i].pos.x += dx
            leaves[i].pos.y += dy
            leaves[i].prevPos.x += dx
            leaves[i].prevPos.y += dy
        }
    }

    private func wakeGroup(_ id: UInt64) {
        for i in leaves.indices where leaves[i].active && leaves[i].group == id {
            // If this surface was behind a higher window, let the leaves fall
            // behind that window rather than popping through it.
            if isCoveredByHigherWindow(leaves[i]) {
                leaves[i].layer = .back
            }
            leaves[i].asleep = false
            leaves[i].sleepTimer = 0
            leaves[i].group = 0
            leaves[i].support = 0
        }
    }

    // MARK: - Leaf simulation

    private func updateLeaves(dt: Float) {
        let tilt = TiltGravity.shared
        let targetGravity = tilt.enabled ? tilt.gravity : SIMD2<Float>(0, 1)
        gravityDir += (targetGravity - gravityDir) * min(1, dt * 6)

        // When the Mac is tilted far enough, wake the settled pile so it can
        // slide in the new direction. Once the tilt is steady, the leaves are
        // allowed to fall asleep again.
        let gravityDelta = length(gravityDir - lastWakeGravity)
        if gravityDelta > 0.08 {
            lastWakeGravity = gravityDir
            for i in leaves.indices where leaves[i].active && leaves[i].asleep {
                leaves[i].asleep = false
                leaves[i].sleepTimer = 0
            }
        }

        if density == .shower && gravityDir.y > 0.5 {
            var topmostGround = height
            for i in leaves.indices where leaves[i].active && leaves[i].asleep
                && leaves[i].group == groundID {
                if leaves[i].pos.y < topmostGround {
                    topmostGround = leaves[i].pos.y
                }
            }
            pileSaturated = height - topmostGround > 220
        } else {
            pileSaturated = false
        }

        for i in leaves.indices {
            var leaf = leaves[i]
            guard leaf.active else { continue }

            if leaf.fading {
                leaf.alpha -= dt * 2.2
                if leaf.alpha <= 0 {
                    leaf.active = false
                    leaf.fading = false
                    leaf.alpha = 1
                    settledCount = max(0, settledCount - 1)
                    if density == .shower && pileSaturated {
                        // The ambient replenisher will refill this slot.
                        leaves[i] = leaf
                        continue
                    }
                    var fresh = Leaf()
                    spawnAmbient(&fresh)
                    leaves[i] = fresh
                    continue
                }
                leaves[i] = leaf
                continue
            }

            if leaf.asleep {
                leaves[i] = leaf
                continue
            }

            leaf.prevPos = leaf.pos
            leaf.vel.x += gravityDir.x * gravityMagnitude * dt
            leaf.vel.y += gravityDir.y * gravityMagnitude * dt
            if leaf.vel.y > leaf.terminal { leaf.vel.y = leaf.terminal }
            leaf.vel.x += (windBase + sin(time * 1.4 + leaf.phase) * leaf.flutter) * dt
            leaf.vel *= 0.995
            leaf.pos += leaf.vel * dt
            leaf.angle += leaf.angVel * dt
            leaf.angVel *= 0.995

            var landed = false
            if leaf.pos.x < leaf.radius {
                leaf.pos.x = leaf.radius
                if leaf.vel.x < 0 { leaf.vel.x = -leaf.vel.x * 0.2 }
                if gravityDir.x < -0.20 {
                    landed = true
                    leaf.layer = .back
                }
            } else if leaf.pos.x > width - leaf.radius {
                leaf.pos.x = width - leaf.radius
                if leaf.vel.x > 0 { leaf.vel.x = -leaf.vel.x * 0.2 }
                if gravityDir.x > 0.20 {
                    landed = true
                    leaf.layer = .back
                }
            }
            if gravityDir.y < -0.25 && leaf.pos.y - leaf.radius < 0 {
                leaf.pos.y = leaf.radius
                if leaf.vel.y < 0 { leaf.vel.y = 0 }
                landed = true
                leaf.layer = .back
            }

            landed = resolveSurface(&leaf) || landed
            resolveIconSides(&leaf)
            resolveWindowSides(&leaf)

            if leaf.pos.y > height + 80 {
                if leaf.ambient {
                    spawnAmbient(&leaf)
                } else {
                    leaf.active = false
                    settledCount = max(0, settledCount - 1)
                }
                leaves[i] = leaf
                continue
            }
            if leaf.pos.y < -height - 80 {
                if leaf.ambient {
                    spawnAmbient(&leaf)
                } else {
                    leaf.active = false
                    settledCount = max(0, settledCount - 1)
                }
                leaves[i] = leaf
                continue
            }

            if landed {
                let speed = sqrt(leaf.vel.x * leaf.vel.x + leaf.vel.y * leaf.vel.y)
                if speed < 4 && abs(leaf.angVel) < 0.08 {
                    leaf.sleepTimer += dt
                    if leaf.sleepTimer > 0.5 {
                        leaf.asleep = true
                        leaf.vel = .zero
                        leaf.angVel = 0
                        if leaf.ambient {
                            leaf.ambient = false
                            leaf.settledAt = time
                            settledCount += 1
                            leaves[i] = leaf
                            spawnAmbientLeaf()
                            continue
                        }
                    }
                } else {
                    leaf.sleepTimer = 0
                }
            } else {
                leaf.sleepTimer = 0
            }

            leaves[i] = leaf
        }

        resolveLeafCollisions(dt: dt)
        resolvePileConstraints()
        pushWithCursor()
        pushWithWindows()
        processPendingSpawns()
        growShowerIfNeeded(dt: dt)
        trimDockPile()
    }

    /// The Dock is a narrow front-layer shelf. Letting a huge pile build there
    /// looks like a compressed strip, so keep it to roughly one layer and let
    /// the excess fall to the desktop behind it.
    private func trimDockPile() {
        guard let dock = surfaces[dockID] else { return }
        let maxLeaves = max(40, Int((dock.x1 - dock.x0) / 14))
        var count = 0
        for i in leaves.indices where leaves[i].active && leaves[i].group == dockID {
            count += 1
        }
        guard count > maxLeaves else { return }
        var released = 0
        let excess = count - maxLeaves
        for i in leaves.indices where leaves[i].active && leaves[i].group == dockID {
            guard released < excess else { break }
            leaves[i].asleep = false
            leaves[i].sleepTimer = 0
            leaves[i].group = 0
            leaves[i].support = 0
            leaves[i].noSupportUntil = time + 0.6
            leaves[i].vel.x += Float.random(in: -25...25)
            leaves[i].vel.y += 12
            released += 1
        }
    }

    /// Shower keeps adding leaves continuously instead of waiting for the pile
    /// to settle. The only brake is keeping the app responsive.

    private func growShowerIfNeeded(dt: Float) {
        guard density == .shower, neverDisappear else { return }
        frameTimeAvg = frameTimeAvg * 0.92 + dt * 0.08
        if pileSaturated {
            showerSpawnAccumulator = 0
            // Keep the air full while the settled pile stays at a stable
            // height. This prevents the bottom from compressing forever and
            // keeps the shower from emptying out.
            var ambient = 0
            for i in leaves.indices where leaves[i].active
                && leaves[i].ambient && !leaves[i].fading {
                ambient += 1
            }
            let limit = frameTimeAvg > 1.0 / 40.0 ? 2 : 8
            var need = min(limit, targetAmbient - ambient)
            while need > 0 {
                if let i = firstInactiveIndex() {
                    spawnAmbient(&leaves[i])
                } else {
                    var leaf = Leaf()
                    spawnAmbient(&leaf)
                    leaves.append(leaf)
                }
                need -= 1
            }
            return
        }

        guard leaves.count < 2000 || frameTimeAvg < 1.0 / 30.0 else {
            showerSpawnAccumulator = 0
            return
        }
        showerSpawnAccumulator += dt * 40
        var added = 0
        while showerSpawnAccumulator >= 1 && added < 4 {
            showerSpawnAccumulator -= 1
            var leaf = Leaf()
            spawnAmbient(&leaf)
            leaves.append(leaf)
            added += 1
        }
    }

    private func resolveSurface(_ leaf: inout Leaf) -> Bool {
        let ignoringSupports = time < leaf.noSupportUntil

        if !ignoringSupports, leaf.support != 0, let s = surfaces[leaf.support],
           !s.isMoving, gravityDir.y > 0.15,
           leaf.pos.x >= s.x0, leaf.pos.x <= s.x1 {
            let sy = s.surfaceY(leaf.pos.x)
            if leaf.pos.y + leaf.radius >= sy - 2,
               leaf.pos.y + leaf.radius <= sy + 16 {
                leaf.pos.y = sy - leaf.radius
                if leaf.vel.y > 0 { leaf.vel.y = 0 }
                leaf.vel.x *= 0.90
                leaf.group = s.id
                leaf.layer = s.layer
                return true
            }
        }
        if leaf.support != 0 {
            leaf.support = 0
            leaf.group = 0
        }
        if ignoringSupports { return false }

        let prevBottom = leaf.prevPos.y + leaf.radius
        let newBottom = leaf.pos.y + leaf.radius
        var best: LeafSurface?
        var bestY = Float.greatestFiniteMagnitude
        for s in surfaces.values {
            guard !s.isMoving else { continue }
            guard leaf.pos.x >= s.x0, leaf.pos.x <= s.x1 else { continue }
            let sy = s.surfaceY(leaf.pos.x)
            if prevBottom <= sy + 4, newBottom >= sy, sy < bestY {
                bestY = sy
                best = s
            }
        }
        if let s = best {
            leaf.pos.y = bestY - leaf.radius
            leaf.vel.y = 0
            leaf.vel.x *= 0.70
            leaf.support = s.id
            leaf.group = s.id
            leaf.layer = s.layer
            leaf.angVel = 0
            return true
        }
        return false
    }

    /// Desktop icons have real vertical sides. Leaves should bump into them
    /// instead of falling through the artwork.
    private func resolveIconSides(_ leaf: inout Leaf) {
        for s in surfaces.values where s.isIcon {
            let leftTop = s.edgeY + (s.baseOffsets.first ?? 0)
            let rightTop = s.edgeY + (s.baseOffsets.last ?? 0)
            let top = leaf.pos.x < (s.x0 + s.x1) * 0.5 ? leftTop : rightTop
            let bottom = s.bottomY
            guard leaf.pos.y + leaf.radius > top,
                  leaf.pos.y - leaf.radius < bottom,
                  leaf.pos.x + leaf.radius > s.x0,
                  leaf.pos.x - leaf.radius < s.x1 else { continue }
            // If the leaf is sitting on the top surface, leave it alone.
            if leaf.pos.y + leaf.radius <= top + 3 { continue }
            if leaf.pos.x < (s.x0 + s.x1) * 0.5 {
                leaf.pos.x = s.x0 - leaf.radius
                if leaf.vel.x > 0 { leaf.vel.x = -leaf.vel.x * 0.25 }
            } else {
                leaf.pos.x = s.x1 + leaf.radius
                if leaf.vel.x < 0 { leaf.vel.x = -leaf.vel.x * 0.25 }
            }
        }
    }

    /// Windows are solid to leaves that are in front of them. A leaf pushed
    /// into a window side should slide/bounce off instead of passing through.
    /// Leaves behind a window stay behind it, so only front-layer leaves collide.
    private func resolveWindowSides(_ leaf: inout Leaf) {
        guard leaf.layer == .front else { return }
        let r = leaf.radius
        for s in surfaces.values where s.isWindow {
            guard leaf.pos.x + r > s.x0, leaf.pos.x - r < s.x1,
                  leaf.pos.y + r > s.edgeY + 2,
                  leaf.pos.y - r < s.bottomY else { continue }
            // Sitting on the top surface is handled by resolveSurface.
            if leaf.pos.y + r <= s.edgeY + 3 { continue }

            let left = leaf.pos.x + r - s.x0
            let right = s.x1 - (leaf.pos.x - r)
            let top = leaf.pos.y + r - s.edgeY
            let bottom = s.bottomY - (leaf.pos.y - r)
            let m = min(min(left, right), min(top, bottom))

            if m == left {
                leaf.pos.x = s.x0 - r
                if leaf.vel.x > 0 { leaf.vel.x = -leaf.vel.x * 0.22 }
            } else if m == right {
                leaf.pos.x = s.x1 + r
                if leaf.vel.x < 0 { leaf.vel.x = -leaf.vel.x * 0.22 }
            } else if m == top {
                leaf.pos.y = s.edgeY - r
                if leaf.vel.y > 0 { leaf.vel.y = 0 }
                leaf.group = s.id
                leaf.support = s.id
            } else {
                leaf.pos.y = s.bottomY + r
                if leaf.vel.y < 0 { leaf.vel.y = 0 }
            }
            leaf.sleepTimer = 0
        }
    }

    private func resolveLeafCollisions(dt: Float) {
        // A couple of relaxation passes keep dense piles from jittering. The
        // buckets are rebuilt each pass because leaves move a little.
        for pass in 0..<2 {
            buildLeafBuckets()
            let relaxation: Float = pass == 0 ? 0.65 : 0.45
            for i in leaves.indices {
                guard leaves[i].active, !leaves[i].asleep, !leaves[i].fading else { continue }
                let cx = Int(floor(leaves[i].pos.x / cellSize))
                let cy = Int(floor(leaves[i].pos.y / cellSize))
                for oy in -1...1 {
                    for ox in -1...1 {
                        let key = (cy + oy) &* 131_071 &+ (cx + ox)
                        guard let list = buckets[key] else { continue }
                        for j in list {
                            guard j != i else { continue }
                            if leaves[j].asleep {
                                // A sleeping leaf is a stable obstacle unless
                                // something hits it hard.
                            } else if j < i {
                                continue
                            } else if !leaves[j].active || leaves[j].fading {
                                continue
                            }
                            collide(i, j, relaxation: relaxation)
                        }
                    }
                }
            }
        }
    }

    private func buildLeafBuckets() {
        buckets.removeAll(keepingCapacity: true)
        for i in leaves.indices where leaves[i].active && !leaves[i].fading {
            let cx = Int(floor(leaves[i].pos.x / cellSize))
            let cy = Int(floor(leaves[i].pos.y / cellSize))
            let key = cy &* 131_071 &+ cx
            buckets[key, default: []].append(i)
        }
    }

    private func collide(_ i: Int, _ j: Int, relaxation: Float) {
        let dx = leaves[j].pos.x - leaves[i].pos.x
        let dy = leaves[j].pos.y - leaves[i].pos.y
        let minDist = leaves[i].radius + leaves[j].radius
        let d2 = dx * dx + dy * dy
        guard d2 < minDist * minDist, d2 > 0.0001 else { return }
        let d = sqrt(d2)
        let nx = dx / d
        let ny = dy / d
        let overlap = minDist - d
        let slop: Float = 0.5
        let correction = max(0, overlap - slop) * relaxation
        guard correction > 0.0001 else { return }

        let rvx = leaves[j].vel.x - leaves[i].vel.x
        let rvy = leaves[j].vel.y - leaves[i].vel.y
        let vn = rvx * nx + rvy * ny
        let tx = -ny
        let ty = nx
        let vt = rvx * tx + rvy * ty

        // Sleeping leaves act like static ground. Only a solid impact wakes
        // them, which is what keeps a settled pile from buzzing constantly.
        if leaves[j].asleep {
            let hardHit = vn < -55 && overlap > minDist * 0.18
            if !hardHit {
                leaves[i].pos.x -= nx * correction
                leaves[i].pos.y -= ny * correction
                if vn < 0 {
                    let impulse = -vn * 0.12
                    leaves[i].vel.x -= nx * impulse
                    leaves[i].vel.y -= ny * impulse
                }
                let friction = vt * 0.18
                leaves[i].vel.x += tx * friction
                leaves[i].vel.y += ty * friction
                if overlap > 1.2 || abs(vn) > 12 {
                    leaves[i].sleepTimer = 0
                }
                return
            }
            leaves[j].asleep = false
            leaves[j].sleepTimer = 0
        }

        let mi = max(1, leaves[i].radius * leaves[i].radius)
        let mj = max(1, leaves[j].radius * leaves[j].radius)
        let total = mi + mj
        let wi = mj / total
        let wj = mi / total

        leaves[i].pos.x -= nx * correction * wi
        leaves[i].pos.y -= ny * correction * wi
        leaves[j].pos.x += nx * correction * wj
        leaves[j].pos.y += ny * correction * wj

        if vn < 0 {
            // Low restitution: leaves should settle, not bounce like rubber.
            let impulse = -vn * 0.18
            leaves[i].vel.x -= nx * impulse * wi
            leaves[i].vel.y -= ny * impulse * wi
            leaves[j].vel.x += nx * impulse * wj
            leaves[j].vel.y += ny * impulse * wj
        }

        let friction = vt * 0.16
        leaves[i].vel.x += tx * friction * wi
        leaves[i].vel.y += ty * friction * wi
        leaves[j].vel.x -= tx * friction * wj
        leaves[j].vel.y -= ty * friction * wj

        if overlap > 1.2 || abs(vn) > 12 {
            leaves[i].sleepTimer = 0
            leaves[j].sleepTimer = 0
        }
    }

    /// Re-apply solid constraints after leaf-leaf collisions, otherwise a
    /// dense pile can squeeze leaves back into a window or through the floor
    /// for a frame.
    private func resolvePileConstraints() {
        let maxSpeed: Float = 1300
        for i in leaves.indices {
            guard leaves[i].active, !leaves[i].asleep, !leaves[i].fading else { continue }
            resolveIconSides(&leaves[i])
            resolveWindowSides(&leaves[i])
            if gravityDir.y > 0.15 && leaves[i].pos.y + leaves[i].radius > height {
                leaves[i].pos.y = height - leaves[i].radius
                if leaves[i].vel.y > 0 { leaves[i].vel.y = 0 }
                leaves[i].layer = .back
            }
            let speed2 = leaves[i].vel.x * leaves[i].vel.x
                + leaves[i].vel.y * leaves[i].vel.y
            if speed2 > maxSpeed * maxSpeed {
                let k = maxSpeed / sqrt(speed2)
                leaves[i].vel.x *= k
                leaves[i].vel.y *= k
            }
        }
    }

    private func pushWithCursor() {
        guard cursorVisible else { return }
        let speed = sqrt(cursorVX * cursorVX + cursorVY * cursorVY)
        guard speed > 20 else { return }
        let cx = Float(cursor.x)
        let cy = Float(cursor.y)
        let down = ScreenGeometry.isMouseDown
        let radius: Float = down ? 75 : 55
        let strength = min(1, speed / 600)
        let push = 35 + 75 * strength
        let dirX = cursorVX / max(1, speed)
        let dirY = cursorVY / max(1, speed)

        for i in leaves.indices {
            guard leaves[i].active, !leaves[i].fading else { continue }
            let dx = leaves[i].pos.x - cx
            let dy = leaves[i].pos.y - cy
            let d2 = dx * dx + dy * dy
            guard d2 < radius * radius else { continue }
            let d = sqrt(max(1, d2))
            let falloff = 1 - d / radius
            let nx = dx / d
            let ny = dy / d
            leaves[i].vel.x += (nx * 0.45 + dirX * 0.85) * push * falloff
            leaves[i].vel.y += (ny * 0.20 + dirY * 0.20) * push * falloff * 0.5
            leaves[i].vel.y -= 4 * falloff
            leaves[i].asleep = false
            leaves[i].sleepTimer = 0
            leaves[i].group = 0
            leaves[i].support = 0
        }
    }

    /// A moving window acts like a big cursor: it shoves nearby leaves out of
    /// its way, with a soft falloff so the air around it feels alive.
    private func pushWithWindows() {
        for s in surfaces.values {
            guard s.isWindow else { continue }
            let speed = sqrt(s.vx * s.vx + s.vy * s.vy)
            guard speed > 40 else { continue }
            let margin: Float = 72
            let dirX = s.vx / speed
            let dirY = s.vy / speed
            let strength = min(1, speed / 800)
            let push = 80 + 140 * strength

            for i in leaves.indices {
                guard leaves[i].active, !leaves[i].fading else { continue }
                guard time >= leaves[i].noPushUntil else { continue }
                let p = leaves[i].pos
                guard p.x > s.x0 - margin, p.x < s.x1 + margin,
                      p.y > s.edgeY - margin, p.y < s.bottomY + margin else { continue }

                // Nearest point on the window rectangle.
                let cx = min(max(p.x, s.x0), s.x1)
                let cy = min(max(p.y, s.edgeY), s.bottomY)
                var nx = p.x - cx
                var ny = p.y - cy
                var dist = sqrt(nx * nx + ny * ny)
                if dist < 0.01 {
                    // Inside the window: push out through the closest edge.
                    let dl = p.x - s.x0
                    let dr = s.x1 - p.x
                    let dt = p.y - s.edgeY
                    let db = s.bottomY - p.y
                    let m = min(min(dl, dr), min(dt, db))
                    if m == dl { nx = -1; ny = 0 }
                    else if m == dr { nx = 1; ny = 0 }
                    else if m == dt { nx = 0; ny = -1 }
                    else { nx = 0; ny = 1 }
                    dist = 0
                } else {
                    nx /= dist
                    ny /= dist
                }
                let falloff = dist >= margin ? 0 : 1 - dist / margin
                let f = falloff * falloff
                leaves[i].vel.x += (dirX * 1.25 + nx * 0.55) * push * f
                leaves[i].vel.y += (dirY * 0.12 + ny * 0.22) * push * f * 0.45
                leaves[i].vel.y -= 2 * f
                leaves[i].vel.x += Float.random(in: -5...5) * f
                leaves[i].asleep = false
                leaves[i].sleepTimer = 0
                leaves[i].group = 0
                leaves[i].support = 0
            }
        }
    }

    // MARK: - Spawning

    private func spawnAmbientLeaf() {
        if let i = firstInactiveIndex() {
            spawnAmbient(&leaves[i])
            return
        }
        if neverDisappear {
            if density == .shower && pileSaturated {
                // Keep the shower going without growing the bottom pile:
                // recycle one old settled leaf and let the fade path reuse
                // that slot for a new falling leaf.
                if let oldest = oldestSettledLeaf() {
                    leaves[oldest].fading = true
                }
                return
            }
            if leaves.count + pendingSpawns < maxLeafCount {
                pendingSpawns += 1
            }
            return
        }
        if let oldest = oldestSettledLeaf() {
            leaves[oldest].fading = true
        }
    }

    private func oldestSettledLeaf() -> Int? {
        var oldest = -1
        var oldestTime = Float.greatestFiniteMagnitude
        for i in leaves.indices where leaves[i].active
            && !leaves[i].ambient && !leaves[i].fading {
            if leaves[i].settledAt < oldestTime {
                oldestTime = leaves[i].settledAt
                oldest = i
            }
        }
        return oldest >= 0 ? oldest : nil
    }

    private func processPendingSpawns() {
        while pendingSpawns > 0 {
            var leaf = Leaf()
            spawnAmbient(&leaf)
            leaves.append(leaf)
            pendingSpawns -= 1
        }
    }

    // MARK: - Rendering

    private func buildInstances() {
        backLeaves.removeAll(keepingCapacity: true)
        frontLeaves.removeAll(keepingCapacity: true)

        var order: [Int] = []
        order.reserveCapacity(leaves.count)
        for i in leaves.indices where leaves[i].active {
            order.append(i)
        }
        // Quantise the depth a little and use the stable leaf index as a
        // tie-breaker. Without this, leaves at nearly the same height swap
        // draw order every frame and a compact pile looks like it is buzzing.
        order.sort {
            let ay = Int(floor(leaves[$0].pos.y * 0.5))
            let by = Int(floor(leaves[$1].pos.y * 0.5))
            if ay != by { return ay < by }
            return $0 < $1
        }

        for i in order {
            let leaf = leaves[i]
            // A leaf resting on a background window must disappear behind a
            // window that is in front of it. Recheck every frame so dragging a
            // window forward/back adapts immediately.
            if isCoveredByHigherWindow(leaf) { continue }
            let inst = LeafInstance(
                pos: leaf.pos,
                size: leaf.size,
                angle: leaf.angle,
                alpha: leaf.alpha,
                shape: leaf.shape,
                flip: leaf.flip,
                tint: leaf.tint
            )
            if leaf.layer == .front {
                frontLeaves.append(inst)
            } else {
                backLeaves.append(inst)
            }
        }

    }

    /// Leaves sitting on a window should be hidden by any window stacked above
    /// that one. This keeps a background window's leaf pile from drawing on top
    /// of the window you are actually using.
    private func isCoveredByHigherWindow(_ leaf: Leaf) -> Bool {
        guard leaf.group != 0,
              let s = surfaces[leaf.group], s.isWindow else { return false }
        let r = leaf.radius
        for other in surfaces.values where other.isWindow && other.zIndex < s.zIndex {
            if leaf.pos.x + r > other.x0, leaf.pos.x - r < other.x1,
               leaf.pos.y + r > other.edgeY, leaf.pos.y - r < other.bottomY {
                return true
            }
        }
        return false
    }
}
