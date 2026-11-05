import AppKit
import QuartzCore

/// Works out where the Dock's visible strip is.
///
/// The Dock's own window is a full-screen transparent surface, so its bounds are
/// useless for us. Instead we read the Dock's preferences (tile size and item
/// count) and the screen's reserved area to reconstruct the pill. This needs no
/// Accessibility or Screen Recording permission.
enum DockGeometry {
    struct Strip {
        var x0: CGFloat
        var edgeY: CGFloat   // local top-left coords: the top edge of the Dock
        var width: CGFloat
    }

    private static var cachedPlist: [String: Any]?
    private static var lastRead: CFTimeInterval = 0
    private static let readInterval: CFTimeInterval = 2.0

    private static func plist() -> [String: Any]? {
        let now = CACurrentMediaTime()
        if now - lastRead > readInterval || cachedPlist == nil {
            lastRead = now
            let path = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist"
            cachedPlist = NSDictionary(contentsOfFile: path) as? [String: Any]
        }
        return cachedPlist
    }

    static func strip(for space: ScreenSpace) -> Strip? {
        // If the system is hiding the Dock (another app is full-screen, or some
        // utility hides it), there is nothing to pile snow on.
        let options = NSApplication.shared.currentSystemPresentationOptions
        if options.contains(.hideDock) { return nil }

        guard let d = plist() else { return nil }
        if let auto = d["autohide"] as? Bool, auto { return nil }

        let orientation = d["orientation"] as? String ?? "bottom"
        guard orientation == "bottom" else { return nil }

        let tile = CGFloat((d["tilesize"] as? NSNumber)?.doubleValue ?? 48)
        let apps = (d["persistent-apps"] as? [Any])?.count ?? 0
        let others = (d["persistent-others"] as? [Any])?.count ?? 0
        let recents = (d["recent-apps"] as? [Any])?.count ?? 0
        let count = max(1, apps + others + recents + 1)   // + the Trash

        let spacing = tile * 0.12
        var width = CGFloat(count) * tile + CGFloat(max(0, count - 1)) * spacing + 24
        width = min(width, space.frame.width - 16)
        guard width > 120 else { return nil }

        let screen = NSScreen.screens.first { $0.frame == space.frame }
        let visible = screen?.visibleFrame ?? space.frame
        let dockHeight = visible.minY - space.frame.minY
        guard dockHeight > 12 else { return nil }

        let edgeY = space.frame.height - dockHeight
        let x0 = (space.frame.width - width) / 2

        return Strip(x0: x0, edgeY: edgeY, width: width)
    }
}
