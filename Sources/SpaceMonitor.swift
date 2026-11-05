import Foundation
import CoreGraphics
import QuartzCore

/// Whether the active Space is a full-screen app.
///
/// macOS has no public API for this. Accessibility would answer it but requires
/// a TCC prompt, so we ask SkyLight directly. If the symbol ever disappears we
/// simply fall back to "not full-screen".
final class SpaceMonitor {
    static let shared = SpaceMonitor()

    private typealias ConnFn = @convention(c) () -> UInt32
    private typealias SpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?

    private var spacesFn: SpacesFn?
    private var connection: UInt32 = 0
    private var lastCheck: CFTimeInterval = 0
    private(set) var isFullScreen = false

    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW
        ) else { return }

        guard let symConn = dlsym(handle, "CGSMainConnectionID"),
              let symSpaces = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return }

        let connFn = unsafeBitCast(symConn, to: ConnFn.self)
        connection = connFn()
        spacesFn = unsafeBitCast(symSpaces, to: SpacesFn.self)

        refresh()
    }

    func refreshIfNeeded(now: CFTimeInterval) {
        // Poll often enough that a Space transition does not leave the overlay
        // drawing the Dock for a visible moment.
        if now - lastCheck < 0.05 { return }
        lastCheck = now
        refresh()
    }

    private func refresh() {
        guard let fn = spacesFn else { return }
        guard let displays = fn(connection)?.takeRetainedValue() as? [[String: Any]] else { return }

        // Space type 4 is a full-screen Space. 0 is a normal desktop.
        var full = false
        for display in displays {
            guard let current = display["Current Space"] as? [String: Any] else { continue }
            let type = (current["type"] as? NSNumber)?.intValue ?? 0
            if type == 4 { full = true }
        }
        isFullScreen = full
    }
}
