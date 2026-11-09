import AppKit
import CoreGraphics
import QuartzCore

/// A window the snow can land on.
final class TrackedWindow {
    let id: CGWindowID
    var bounds: CGRect          // global CG coords, top-left origin
    var previousBounds: CGRect
    var velocity: CGPoint = .zero   // points per second
    var zIndex: Int = 0             // 0 = frontmost
    var isDock: Bool = false
    var shakeUntil: CFTimeInterval = 0
    var history: [(t: CFTimeInterval, x: CGFloat, y: CGFloat)] = []

    init(id: CGWindowID, bounds: CGRect, isDock: Bool, zIndex: Int) {
        self.id = id
        self.bounds = bounds
        self.previousBounds = bounds
        self.isDock = isDock
        self.zIndex = zIndex
    }
}

/// Polls the window server for on-screen window geometry.
///
/// This only needs `CGWindowListCopyWindowInfo` bounds, which do **not** require
/// Screen Recording permission. (Titles would — we don't use them.)
final class WindowTracker {
    static let shared = WindowTracker()

    private(set) var windows: [TrackedWindow] = []
    /// True while Mission Control / Exposé is showing its window layer.
    private(set) var isMissionControl = false

    private let pollInterval: CFTimeInterval = 1.0 / 60.0
    private var lastPoll: CFTimeInterval = 0
    private var cache: [CGWindowID: TrackedWindow] = [:]

    private init() {}

    func refreshIfNeeded(now: CFTimeInterval) {
        if now - lastPoll < pollInterval { return }
        lastPoll = now
        refresh(now: now)
    }

    private func refresh(now: CFTimeInterval) {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        isMissionControl = false

        // A Space transition moves every window at once. Do not let that read
        // as a shake or a real drag velocity.
        if SpaceMonitor.shared.isSpaceTransitioning {
            for w in cache.values {
                w.velocity = .zero
                w.history.removeAll()
            }
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        var seen: [CGWindowID: Int] = [:]
        var ordered: [TrackedWindow] = []

        let kNumber = kCGWindowNumber as String
        let kPID = kCGWindowOwnerPID as String
        let kLayer = kCGWindowLayer as String
        let kAlpha = kCGWindowAlpha as String
        let kBounds = kCGWindowBounds as String
        let kOwner = kCGWindowOwnerName as String

        for (index, info) in raw.enumerated() {
            guard let widNum = info[kNumber] as? NSNumber else { continue }
            let wid = CGWindowID(widNum.uint32Value)

            let pid = (info[kPID] as? NSNumber)?.int32Value ?? 0
            if pid == myPID { continue }

            let layer = (info[kLayer] as? NSNumber)?.intValue ?? 0
            let alpha = (info[kAlpha] as? NSNumber)?.doubleValue ?? 1

            guard let bdict = info[kBounds] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bdict) else { continue }

            let owner = info[kOwner] as? String ?? ""
            // Mission Control adds a Dock-owned window just above the top of
            // the screen. It is the reliable signal that the window layer is
            // active, so the snow overlay can hide itself.
            if owner == "Dock" && rect.minY <= -0.5 {
                isMissionControl = true
            }

            if alpha < 0.02 { continue }
            if rect.width < 40 || rect.height < 20 { continue }
            let isDock = (owner == "Dock")
                && layer == 20
                && rect.height >= 20 && rect.height < 400
                && rect.width >= 100
                && rect.minY > ScreenGeometry.mainHeight * 0.35

            let isNormal = layer == 0 && rect.width >= 120 && rect.height >= 70
            guard isNormal || isDock else { continue }

            seen[wid] = index

            let w: TrackedWindow
            if let existing = cache[wid] {
                existing.previousBounds = existing.bounds
                existing.bounds = rect
                existing.isDock = isDock
                existing.zIndex = index
                w = existing
            } else {
                w = TrackedWindow(id: wid, bounds: rect, isDock: isDock, zIndex: index)
                cache[wid] = w
            }
            ordered.append(w)
        }

        // Drop windows that vanished.
        for (id, _) in cache where seen[id] == nil {
            cache.removeValue(forKey: id)
        }

        let dt = max(pollInterval, 0.0001)
        for w in ordered {
            let dx = w.bounds.minX - w.previousBounds.minX
            let dy = w.bounds.minY - w.previousBounds.minY
            if abs(dx) > 0.01 || abs(dy) > 0.01 {
                w.velocity = CGPoint(x: dx / dt, y: dy / dt)
            } else {
                w.velocity = .zero
            }
            detectShake(w, now: now)
        }

        windows = ordered
    }

    /// A shake is a rapid left-right reversal of the window origin.
    /// Fast dragging has speed but no reversals, so it won't trigger.
    private func detectShake(_ w: TrackedWindow, now: CFTimeInterval) {
        // Resizing, minimising or a Space swipe changes the window size. That
        // is not a shake, and feeding it to the detector produces wild motion.
        let dw = abs(w.bounds.width - w.previousBounds.width)
        let dh = abs(w.bounds.height - w.previousBounds.height)
        if dw > 2 || dh > 2 {
            w.history.removeAll()
            return
        }

        w.history.append((now, w.bounds.minX, w.bounds.minY))
        w.history.removeAll { now - $0.t > 0.45 }

        guard w.history.count >= 4 else { return }

        var reversals = 0
        var lastSign = 0
        var amplitude: CGFloat = 0

        for i in 1..<w.history.count {
            let dx = w.history[i].x - w.history[i - 1].x
            if abs(dx) < 5 { continue }
            amplitude += abs(dx)
            let sign = dx > 0 ? 1 : -1
            if lastSign != 0 && sign != lastSign { reversals += 1 }
            lastSign = sign
        }

        if reversals >= 4 && amplitude > 55 {
            w.shakeUntil = now + 0.30
            w.history.removeAll()
        }
    }
}
