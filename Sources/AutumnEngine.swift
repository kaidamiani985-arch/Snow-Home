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

/// A single leaf. Falling leaves move; settled leaves are static and live in
/// the pile grid until something wakes them.
private struct Leaf {
    var pos = SIMD2<Float>(0, 0)
    var prevPos = SIMD2<Float>(0, 0)
    var vel = SIMD2<Float>(0, 0)
    var size: Float = 12
    var angle: Float = 0
    var shape: Float = 0
    var flip: Float = 0
    var tint = SIMD4<Float>(1, 1, 1, 1)
    var layer: SnowLayer = .back
    /// 0 = falling, otherwise the surface id it is resting on.
    var surface: UInt64 = 0
    var active = false
    var settledAt: Float = 0
    var phase: Float = 0
    var flutter: Float = 0
    var terminal: Float = 60
    var alpha: Float = 1
}

private struct LeafSurface {
    let id: UInt64
    var layer: SnowLayer
    var x0: Float
    var x1: Float
    var edgeY: Float
    var bottomY: Float
    var baseOffsets: [Float]
    var isDock: Bool
    var isIcon: Bool
    var isWindow: Bool
    var zIndex: Int
    var vx: Float = 0
    var vy: Float = 0
    var lastUpdate: Float = 0

    func surfaceY(_ x: Float) -> Float {
        let idx = Int((x - x0) / Platform.cell)
        guard idx >= 0 && idx < baseOffsets.count else { return edgeY }
        return edgeY + baseOffsets[idx]
    }

    var isMoving: Bool {
        guard isWindow else { return false }
        return vx * vx + vy * vy > 40 * 40
    }

    /// How deep a pile may grow on this surface before leaves fall past it.
    func maxPileDepth(screenHeight: Float) -> Float {
        if isIcon { return 70 }
        if isDock { return 70 }
        if isWindow { return 150 }
        return screenHeight * 0.78
    }
}

/// Autumn leaves: individual sprites, a stable pile-placement grid, and no
/// continuous leaf-on-leaf collision solver.
final class AutumnEngine: SeasonEngine {
    let space: ScreenSpace
    let width: Float
    let height: Float

    private(set) var backLeaves: [LeafInstance] = []
    private(set) var frontLeaves: [LeafInstance] = []

    private var leaves: [Leaf] = []
    private var surfaces: [UInt64: LeafSurface] = [:]
    /// surface id -> grid column -> settled leaf indices
    private var settledGrid: [UInt64: [Int: [Int]]] = [:]
    private var iconIDs: [String: UInt64] = [:]
    private var nextIconID: UInt64 = 3_000_000

    private var density: SnowDensity
    private var time: Float = 0
    private var lastStep: CFTimeInterval = 0
    private var freezeUntil: Float = 0
    private var resetWindowSurfaces = false

    private var cursor = CGPoint.zero
    private var cursorVisible = false
    private var lastCursor = CGPoint.zero
    private var hasLastCursor = false
    private var cursorVX: Float = 0
    private var cursorVY: Float = 0

    private var windBase: Float = 0
    private var neverDisappear = false
    private var settledCount = 0
    private var targetAmbient = 0
    private var gravityDir = SIMD2<Float>(0, 1)
    private let gravityMagnitude: Float = 40

    private let groundID: UInt64 = 1
    private let dockID: UInt64 = 2
    private let gridCell: Float = 28

    private let palette: [SIMD4<Float>] = [
        SIMD4(0.82, 0.34, 0.08, 1),
        SIMD4(0.90, 0.52, 0.10, 1),
        SIMD4(0.95, 0.72, 0.12, 1),
        SIMD4(0.72, 0.20, 0.10, 1),
        SIMD4(0.62, 0.16, 0.08, 1),
        SIMD4(0.55, 0.32, 0.10, 1),
        SIMD4(0.86, 0.42, 0.14, 1),
        SIMD4(0.78, 0.60, 0.14, 1)
    ]

    init(space: ScreenSpace, density: SnowDensity) {
        self.space = space
        self.width = Float(space.size.width)
        self.height = Float(space.size.height)
        self.density = density
        surfaces[groundID] = LeafSurface(
            id: groundID, layer: .back, x0: 0, x1: self.width,
            edgeY: self.height, bottomY: self.height, baseOffsets: [],
            isDock: false, isIcon: false, isWindow: false, zIndex: 0
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
        settledGrid.removeAll(keepingCapacity: true)
        settledCount = 0
        backLeaves.removeAll(keepingCapacity: true)
        frontLeaves.removeAll(keepingCapacity: true)
        targetAmbient = density == .shower
            ? Int(Float(count) * 0.70)
            : Int(Float(count) * 0.30)

        let initialSettled = density == .shower
            ? Int(Float(count) * 0.10)
            : Int(Float(count) * 0.15)
        for _ in 0..<initialSettled {
            guard let i = firstInactiveIndex() else { break }
            var leaf = Leaf()
            settleInitialGround(&leaf, index: i)
            leaves[i] = leaf
        }
        for _ in 0..<min(targetAmbient, count - settledCount) {
            guard let i = firstInactiveIndex() else { break }
            spawnAmbient(&leaves[i])
        }
    }

    private func firstInactiveIndex() -> Int? {
        for i in leaves.indices where !leaves[i].active { return i }
        return nil
    }

    private func resetCommon(_ leaf: inout Leaf) {
        leaf = Leaf()
        leaf.size = Float.random(in: 7...13)
        leaf.angle = Float.random(in: 0..<6.283)
        leaf.shape = Float(Int.random(in: 0..<8))
        leaf.flip = Float.random(in: 0..<1) < 0.5 ? 0 : 1
        leaf.tint = palette.randomElement() ?? palette[0]
        leaf.phase = Float.random(in: 0..<6.283)
        leaf.alpha = Float.random(in: 0.88...1.0)
    }

    private func spawnAmbient(_ leaf: inout Leaf) {
        resetCommon(&leaf)
        leaf.pos.x = Float.random(in: -20...(width + 20))
        leaf.pos.y = -Float.random(in: 10...70)
        leaf.prevPos = leaf.pos
        leaf.vel = SIMD2(
            Float.random(in: -8...8) + gravityDir.x * 30,
            Float.random(in: 20...50)
        )
        leaf.terminal = Float.random(in: 55...105)
        leaf.flutter = Float.random(in: 3...9)
        leaf.layer = Float.random(in: 0..<1) < 0.65 ? .front : .back
        leaf.surface = 0
        leaf.active = true
        leaf.alpha = 1
    }

    private func settleInitialGround(_ leaf: inout Leaf, index: Int) {
        resetCommon(&leaf)
        leaf.pos.x = Float.random(in: 20...(width - 20))
        let top = pileTop(surfaceID: groundID, x: leaf.pos.x, size: leaf.size)
        leaf.pos.y = top - leaf.size * 0.65
        leaf.prevPos = leaf.pos
        leaf.surface = groundID
        leaf.layer = .back
        leaf.active = true
        leaf.settledAt = 0
        addToGrid(leafIndex: index, surface: groundID, x: leaf.pos.x)
        settledCount += 1
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

        // Freeze through a three-finger Space swipe so leaves are not dragged.
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
        if time < freezeUntil { return }
        if resetWindowSurfaces {
            resetWindowSurfaces = false
            for (id, surface) in surfaces where surface.isWindow {
                wakeSurface(id)
                surfaces.removeValue(forKey: id)
            }
        }

        syncSurfaces(now: now)
        updateWind()
        updateGravity()
        updateLeaves(dt: dt)
        maintainAmbientCount()
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

    private func updateGravity() {
        let tilt = TiltGravity.shared
        let target = tilt.enabled ? tilt.gravity : SIMD2<Float>(0, 1)
        let previous = gravityDir
        gravityDir = target
        if length(gravityDir - previous) > 0.12 {
            // A real tilt: let the pile fall and re-settle in the new direction.
            wakeAllSettled()
        }
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

            if let old = surfaces[id],
               (x1 - x0) < (old.x1 - old.x0) * 0.82,
               edgeY > old.edgeY + 14 {
                wakeSurface(id)
                surfaces.removeValue(forKey: id)
                continue
            }

            updateSurface(
                id: id, layer: .front, x0: x0, x1: x1,
                edgeY: edgeY, baseOffsets: [],
                isDock: false, isIcon: false, isWindow: true,
                bottomY: Float(lr.maxY), zIndex: w.zIndex, seen: &seen
            )
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
                updateSurface(
                    id: dockID, layer: .front, x0: x0, x1: x1,
                    edgeY: Float(dock.edgeY), baseOffsets: [],
                    isDock: true, isIcon: false, isWindow: false,
                    bottomY: Float(dock.edgeY) + 90, zIndex: 0, seen: &seen
                )
            }
        } else if surfaces[dockID] != nil {
            wakeSurface(dockID)
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
            updateSurface(
                id: id, layer: .back, x0: x0, x1: x0 + w,
                edgeY: Float(lr.minY), baseOffsets: icon.profile,
                isDock: false, isIcon: true, isWindow: false,
                bottomY: Float(lr.maxY), zIndex: 0, seen: &seen
            )
        }

        updateSurface(
            id: groundID, layer: .back, x0: 0, x1: width,
            edgeY: height, baseOffsets: [],
            isDock: false, isIcon: false, isWindow: false,
            bottomY: height, zIndex: 0, seen: &seen
        )

        for (id, _) in surfaces where !seen.contains(id) {
            wakeSurface(id)
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

    private func updateSurface(
        id: UInt64, layer: SnowLayer, x0: Float, x1: Float,
        edgeY: Float, baseOffsets: [Float],
        isDock: Bool, isIcon: Bool, isWindow: Bool,
        bottomY: Float, zIndex: Int, seen: inout Set<UInt64>
    ) {
        seen.insert(id)
        if var s = surfaces[id] {
            let dx = x0 - s.x0
            let dy = edgeY - s.edgeY
            let dtS = max(1.0 / 240.0, time - s.lastUpdate)
            s.lastUpdate = time
            s.vx = s.vx * 0.55 + max(-4000, min(4000, dx / dtS)) * 0.45
            s.vy = s.vy * 0.55 + max(-4000, min(4000, dy / dtS)) * 0.45
            s.layer = layer
            s.x0 = x0
            s.x1 = x1
            s.edgeY = edgeY
            s.baseOffsets = baseOffsets
            s.isDock = isDock
            s.isIcon = isIcon
            s.isWindow = isWindow
            s.bottomY = bottomY
            s.zIndex = zIndex
            surfaces[id] = s
            if isWindow && (abs(dx) > 0.4 || abs(dy) > 0.4) {
                wakeSurface(id)
            }
        } else {
            surfaces[id] = LeafSurface(
                id: id, layer: layer, x0: x0, x1: x1,
                edgeY: edgeY, bottomY: bottomY, baseOffsets: baseOffsets,
                isDock: isDock, isIcon: isIcon, isWindow: isWindow,
                zIndex: zIndex, lastUpdate: time
            )
        }
    }

    // MARK: - Gravity / tilt

    // MARK: - Leaf simulation

    private func updateLeaves(dt: Float) {
        for i in leaves.indices {
            var leaf = leaves[i]
            guard leaf.active, leaf.surface == 0 else { continue }

            leaf.prevPos = leaf.pos
            leaf.vel.x += gravityDir.x * gravityMagnitude * dt
            leaf.vel.y += gravityDir.y * gravityMagnitude * dt
            if leaf.vel.y > leaf.terminal { leaf.vel.y = leaf.terminal }
            leaf.vel.x += (windBase + sin(time * 1.4 + leaf.phase) * leaf.flutter) * dt
            leaf.vel *= 0.995
            leaf.pos += leaf.vel * dt
            leaf.angle += 0.6 * dt * sin(leaf.phase + time)

            if leaf.pos.x < leaf.size * 0.5 {
                leaf.pos.x = leaf.size * 0.5
                if leaf.vel.x < 0 { leaf.vel.x = -leaf.vel.x * 0.2 }
            } else if leaf.pos.x > width - leaf.size * 0.5 {
                leaf.pos.x = width - leaf.size * 0.5
                if leaf.vel.x > 0 { leaf.vel.x = -leaf.vel.x * 0.2 }
            }

            resolveFallingSides(&leaf)

            if tryLand(&leaf, index: i) {
                leaves[i] = leaf
                continue
            }

            if leaf.pos.y > height + 120 {
                leaf.active = false
                leaves[i] = leaf
                continue
            }

            leaves[i] = leaf
        }

        pushWithCursor()
        pushWithWindows()
    }

    /// Land a falling leaf on the highest surface/pile it crosses.
    private func tryLand(_ leaf: inout Leaf, index: Int) -> Bool {
        let bottom = leaf.size * 0.62
        let prevBottom = leaf.prevPos.y + bottom
        let newBottom = leaf.pos.y + bottom
        var best: LeafSurface?
        var bestTop = Float.greatestFiniteMagnitude

        for s in surfaces.values {
            guard !s.isMoving else { continue }
            guard leaf.pos.x >= s.x0, leaf.pos.x <= s.x1 else { continue }
            let top = pileTop(surfaceID: s.id, x: leaf.pos.x, size: leaf.size)
            if prevBottom <= top + 6, newBottom >= top, top < bestTop {
                let depth = s.edgeY - top
                if depth <= s.maxPileDepth(screenHeight: height) {
                    bestTop = top
                    best = s
                }
            }
        }

        guard let s = best else { return false }
        let landingY = bestTop - leaf.size * 0.65
        leaf.pos.y = landingY
        leaf.pos.x += Float.random(in: -leaf.size * 0.16...leaf.size * 0.16)
        leaf.vel = .zero
        leaf.surface = s.id
        leaf.layer = s.layer
        leaf.settledAt = time
        addToGrid(leafIndex: index, surface: s.id, x: leaf.pos.x)
        settledCount += 1
        return true
    }

    // MARK: - Pile grid

    private func addToGrid(leafIndex: Int, surface: UInt64, x: Float) {
        guard leafIndex >= 0 else { return }
        let cell = Int(floor(x / gridCell))
        settledGrid[surface, default: [:]][cell, default: []].append(leafIndex)
    }

    private func removeFromGrid(leafIndex: Int, surface: UInt64, x: Float) {
        let cell = Int(floor(x / gridCell))
        settledGrid[surface]?[cell]?.removeAll { $0 == leafIndex }
    }

    private func pileTop(surfaceID: UInt64, x: Float, size: Float) -> Float {
        guard let s = surfaces[surfaceID] else { return height }
        var top = s.surfaceY(x)
        let cell = Int(floor(x / gridCell))
        for c in (cell - 2)...(cell + 2) {
            guard let list = settledGrid[surfaceID]?[c] else { continue }
            for j in list {
                let other = leaves[j]
                guard other.active, other.surface == surfaceID else { continue }
                if abs(other.pos.x - x) < (other.size + size) * 0.72 {
                    top = min(top, other.pos.y - other.size * 0.60)
                }
            }
        }
        return top
    }

    private func wakeAllSettled() {
        for i in leaves.indices where leaves[i].active && leaves[i].surface != 0 {
            wakeSettled(i, cascade: false)
        }
    }

    private func wakeSurface(_ id: UInt64) {
        for i in leaves.indices where leaves[i].active && leaves[i].surface == id {
            wakeSettled(i, cascade: false)
        }
    }

    private func wakeSettled(_ index: Int, cascade: Bool) {
        guard leaves[index].active, leaves[index].surface != 0 else { return }
        let s = leaves[index].surface
        let x = leaves[index].pos.x
        let y = leaves[index].pos.y
        removeFromGrid(leafIndex: index, surface: s, x: x)
        leaves[index].surface = 0
        leaves[index].settledAt = 0
        leaves[index].pos.y -= 2
        leaves[index].vel = SIMD2(
            Float.random(in: -25...25),
            -25 - Float.random(in: 0...15)
        )
        settledCount = max(0, settledCount - 1)

        guard cascade else { return }
        let cell = Int(floor(x / gridCell))
        for c in (cell - 1)...(cell + 1) {
            let list = settledGrid[s]?[c] ?? []
            for j in list where leaves[j].active && leaves[j].surface == s
                && leaves[j].pos.y < y {
                wakeSettled(j, cascade: true)
            }
        }
    }

    // MARK: - Pushes

    private func pushWithCursor() {
        guard cursorVisible else { return }
        let speed = sqrt(cursorVX * cursorVX + cursorVY * cursorVY)
        guard speed > 20 else { return }
        let cx = Float(cursor.x)
        let cy = Float(cursor.y)
        let down = ScreenGeometry.isMouseDown
        let radius: Float = down ? 80 : 60
        let strength = min(1, speed / 600)
        let push = 45 + 95 * strength
        let dirX = cursorVX / max(1, speed)
        let dirY = cursorVY / max(1, speed)

        for i in leaves.indices {
            guard leaves[i].active else { continue }
            let dx = leaves[i].pos.x - cx
            let dy = leaves[i].pos.y - cy
            let d2 = dx * dx + dy * dy
            guard d2 < radius * radius else { continue }
            if leaves[i].surface != 0 {
                wakeSettled(i, cascade: true)
            }
            let d = sqrt(max(1, d2))
            let falloff = 1 - d / radius
            let nx = dx / d
            let ny = dy / d
            leaves[i].vel.x += (nx * 0.45 + dirX * 0.85) * push * falloff
            leaves[i].vel.y += (ny * 0.20 + dirY * 0.20) * push * falloff * 0.5
            leaves[i].vel.y -= 4 * falloff
        }
    }

    private func pushWithWindows() {
        for s in surfaces.values where s.isWindow {
            let speed = sqrt(s.vx * s.vx + s.vy * s.vy)
            guard speed > 40 else { continue }
            let margin: Float = 72
            let dirX = s.vx / speed
            let dirY = s.vy / speed
            let strength = min(1, speed / 800)
            let push = 80 + 140 * strength

            for i in leaves.indices {
                guard leaves[i].active else { continue }
                let p = leaves[i].pos
                guard p.x > s.x0 - margin, p.x < s.x1 + margin,
                      p.y > s.edgeY - margin, p.y < s.bottomY + margin else { continue }
                if leaves[i].surface != 0 {
                    wakeSettled(i, cascade: true)
                }
                let cx = min(max(p.x, s.x0), s.x1)
                let cy = min(max(p.y, s.edgeY), s.bottomY)
                var nx = p.x - cx
                var ny = p.y - cy
                var dist = sqrt(nx * nx + ny * ny)
                if dist < 0.01 {
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
            }
        }
    }

    private func resolveFallingSides(_ leaf: inout Leaf) {
        guard leaf.layer == .front else { return }
        let r = leaf.size * 0.75
        for s in surfaces.values where s.isIcon || s.isWindow {
            let top = s.isIcon
                ? s.edgeY + (s.baseOffsets.first ?? 0)
                : s.edgeY
            let bottom = s.bottomY
            guard leaf.pos.y + r > top + 2,
                  leaf.pos.y - r < bottom,
                  leaf.pos.x + r > s.x0,
                  leaf.pos.x - r < s.x1 else { continue }
            if leaf.pos.y + r <= top + 3 { continue }
            if leaf.pos.x < (s.x0 + s.x1) * 0.5 {
                leaf.pos.x = s.x0 - r
                if leaf.vel.x > 0 { leaf.vel.x = -leaf.vel.x * 0.22 }
            } else {
                leaf.pos.x = s.x1 + r
                if leaf.vel.x < 0 { leaf.vel.x = -leaf.vel.x * 0.22 }
            }
        }
    }

    // MARK: - Ambient count

    private func maintainAmbientCount() {
        var falling = 0
        for i in leaves.indices where leaves[i].active && leaves[i].surface == 0 {
            falling += 1
        }
        var need = min(8, targetAmbient - falling)
        while need > 0 {
            if let i = firstInactiveIndex() {
                spawnAmbient(&leaves[i])
            } else if density == .shower && neverDisappear {
                if settledCount > 0, pileIsFull() {
                    guard let oldest = oldestSettledIndex() else { break }
                    wakeSettled(oldest, cascade: false)
                    spawnAmbient(&leaves[oldest])
                } else {
                    var leaf = Leaf()
                    spawnAmbient(&leaf)
                    leaves.append(leaf)
                }
            } else if let oldest = oldestSettledIndex() {
                wakeSettled(oldest, cascade: false)
                spawnAmbient(&leaves[oldest])
            } else {
                break
            }
            need -= 1
        }
    }

    private func pileIsFull() -> Bool {
        guard let s = surfaces[groundID] else { return false }
        var top = height
        if let grid = settledGrid[groundID] {
            for (_, list) in grid {
                for j in list where leaves[j].active && leaves[j].surface == groundID {
                    top = min(top, leaves[j].pos.y)
                }
            }
        }
        return s.edgeY - top > s.maxPileDepth(screenHeight: height) * 0.98
    }

    private func oldestSettledIndex() -> Int? {
        var oldest = -1
        var oldestTime = Float.greatestFiniteMagnitude
        for i in leaves.indices where leaves[i].active && leaves[i].surface != 0 {
            if leaves[i].settledAt < oldestTime {
                oldestTime = leaves[i].settledAt
                oldest = i
            }
        }
        return oldest >= 0 ? oldest : nil
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
        order.sort {
            let ay = Int(floor(leaves[$0].pos.y * 0.5))
            let by = Int(floor(leaves[$1].pos.y * 0.5))
            if ay != by { return ay < by }
            return $0 < $1
        }

        for i in order {
            let leaf = leaves[i]
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

    private func isCoveredByHigherWindow(_ leaf: Leaf) -> Bool {
        guard leaf.surface != 0,
              let s = surfaces[leaf.surface], s.isWindow else { return false }
        let r = leaf.size
        for other in surfaces.values where other.isWindow && other.zIndex < s.zIndex {
            if leaf.pos.x + r > other.x0, leaf.pos.x - r < other.x1,
               leaf.pos.y + r > other.edgeY, leaf.pos.y - r < other.bottomY {
                return true
            }
        }
        return false
    }
}
