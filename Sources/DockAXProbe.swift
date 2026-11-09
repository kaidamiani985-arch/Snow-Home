import AppKit
import ApplicationServices

/// Diagnostic: dumps the Dock's Accessibility tree so we can find the real
/// on-screen frame of the Dock pill.
enum DockAXProbe {
    static func run() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            print("Dock not running")
            return
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var out = "Dock AX tree\n"
        dump(app, depth: 0, maxDepth: 7, out: &out)
        try? out.write(toFile: "/tmp/snow_dock_ax.txt", atomically: true, encoding: .utf8)
        print("wrote /tmp/snow_dock_ax.txt")
    }

    private static func str(_ value: CFTypeRef?) -> String {
        guard let value else { return "" }
        return "\(value)"
    }

    private static func dump(_ e: AXUIElement, depth: Int, maxDepth: Int, out: inout String) {
        guard depth <= maxDepth else { return }
        var role: CFTypeRef?
        var title: CFTypeRef?
        var desc: CFTypeRef?
        var pos: CFTypeRef?
        var size: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(e, kAXDescriptionAttribute as CFString, &desc)
        AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos)
        AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size)
        var p = CGPoint.zero
        var s = CGSize.zero
        if let pos, CFGetTypeID(pos) == AXValueGetTypeID() {
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        }
        if let size, CFGetTypeID(size) == AXValueGetTypeID() {
            AXValueGetValue(size as! AXValue, .cgSize, &s)
        }
        out += "\(String(repeating: "  ", count: depth))role=\(str(role)) title=\(str(title)) desc=\(str(desc)) pos=(\(p.x),\(p.y)) size=(\(s.width),\(s.height))\n"
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
           let arr = children as? [AXUIElement] {
            for c in arr { dump(c, depth: depth + 1, maxDepth: maxDepth, out: &out) }
        }
    }
}
