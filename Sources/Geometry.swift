import AppKit
import CoreGraphics

/// Which physical plane a bit of snow lives on.
/// `.back`  -> behind every app window (the desktop plane)
/// `.front` -> in front of app windows (resting on / falling past them)
enum SnowLayer: Int {
    case back = 0
    case front = 1
}

/// Maps global CoreGraphics coordinates (origin = top-left of the main display,
/// y grows downward) into a single display's local top-left space.
struct ScreenSpace {
    let frame: CGRect      // AppKit global frame (bottom-left origin)
    let mainHeight: CGFloat

    init(screen: NSScreen, mainHeight: CGFloat) {
        self.frame = screen.frame
        self.mainHeight = mainHeight
    }

    var size: CGSize { frame.size }

    /// Height of the menu bar band at the top of this display, in local coords.
    /// Zero on displays without a menu bar.
    var topInset: CGFloat {
        let visible = NSScreen.screens.first(where: { $0.frame == frame })?.visibleFrame
        guard let visible else { return 0 }
        let inset = frame.height - (visible.maxY - frame.minY)
        return max(0, inset)
    }

    /// CG global origin of this screen, in CG (top-left) space.
    var cgOrigin: CGPoint {
        CGPoint(x: frame.minX, y: mainHeight - frame.maxY)
    }

    func toLocal(_ global: CGRect) -> CGRect {
        CGRect(
            x: global.minX - cgOrigin.x,
            y: global.minY - cgOrigin.y,
            width: global.width,
            height: global.height
        )
    }

    func toLocal(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - cgOrigin.x, y: point.y - cgOrigin.y)
    }
}

enum ScreenGeometry {
    /// Height of the primary display, used to flip AppKit's bottom-left origin
    /// into the window server's top-left origin.
    static var mainHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Current cursor position in a screen's local top-left space.
    /// `NSEvent.mouseLocation` needs no privacy permission.
    static func cursorLocal(in space: ScreenSpace) -> CGPoint {
        let p = NSEvent.mouseLocation
        let cg = CGPoint(x: p.x, y: space.mainHeight - p.y)
        return space.toLocal(cg)
    }

    static var isMouseDown: Bool {
        NSEvent.pressedMouseButtons & 1 != 0
    }
}
