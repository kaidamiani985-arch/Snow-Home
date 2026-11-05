import AppKit
import ApplicationServices

/// Diagnostic: dumps Finder's Accessibility tree so we can see how the desktop
/// icons are exposed. Run with `SnowOnMac --ax-probe`.
enum AXProbe {
    static let outputPath = "/tmp/snow_ax.txt"

    static func run() {
        var out = ""
        func emit(_ s: String) { out += s + "\n" }

        guard AXIsProcessTrusted() else {
            emit("AX NOT TRUSTED")
            try? out.write(toFile: outputPath, atomically: true, encoding: .utf8)
            return
        }

        guard let finder = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            emit("FINDER NOT RUNNING")
            try? out.write(toFile: outputPath, atomically: true, encoding: .utf8)
            return
        }

        emit("Finder pid: \(finder.processIdentifier)")
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        dump(app, depth: 0, maxDepth: 6, emit: emit)
        try? out.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(e, name as CFString, &v)
        return err == .success ? v : nil
    }

    private static func dump(_ e: AXUIElement, depth: Int, maxDepth: Int,
                             emit: (String) -> Void) {
        let role = attr(e, kAXRoleAttribute) as? String ?? "?"
        let sub = attr(e, kAXSubroleAttribute) as? String ?? ""
        let title = attr(e, kAXTitleAttribute) as? String ?? ""

        var pos = CGPoint.zero
        var size = CGSize.zero
        if let pv = attr(e, kAXPositionAttribute) {
            AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        }
        if let sv = attr(e, kAXSizeAttribute) {
            AXValueGetValue(sv as! AXValue, .cgSize, &size)
        }

        let pad = String(repeating: "  ", count: depth)
        emit("\(pad)\(role)/\(sub) '\(title)' pos=(\(Int(pos.x)),\(Int(pos.y))) size=(\(Int(size.width))x\(Int(size.height)))")

        guard depth < maxDepth else { return }
        if let children = attr(e, kAXChildrenAttribute) as? [AXUIElement] {
            for c in children.prefix(400) {
                dump(c, depth: depth + 1, maxDepth: maxDepth, emit: emit)
            }
        }
    }
}
