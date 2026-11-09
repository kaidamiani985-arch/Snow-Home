import AppKit
import ApplicationServices
import QuartzCore

/// Reads the real Dock pill frame from the Dock's Accessibility tree.
///
/// The Dock's window-server window is a full-screen transparent surface, so its
/// bounds are useless. The Accessibility list inside it, however, has the exact
/// on-screen frame of the Dock items. That frame changes when apps are added or
/// removed, which is what the snow cap needs to follow.
enum DockAX {
    struct Frame {
        var x: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    private static var cached: Frame?
    private static var lastRead: CFTimeInterval = 0
    private static let readInterval: CFTimeInterval = 1.0

    static func pillFrame() -> Frame? {
        let now = CACurrentMediaTime()
        if now - lastRead < readInterval { return cached }
        lastRead = now
        cached = query()
        return cached
    }

    private static func query() -> Frame? {
        guard AXIsProcessTrusted() else { return nil }
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first else { return nil }

        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }

        for element in list {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard let role, "\(role)" == "AXList" else { continue }

            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)

            var p = CGPoint.zero
            var s = CGSize.zero
            if let posRef, CFGetTypeID(posRef) == AXValueGetTypeID() {
                AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
            }
            if let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() {
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
            }
            guard s.width > 100, s.height > 20 else { continue }
            return Frame(x: p.x, width: s.width, height: s.height)
        }
        return nil
    }
}
