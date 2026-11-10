import AppKit
import QuartzCore

if CommandLine.arguments.contains("--ax-probe") {
    AXProbe.run()
    exit(0)
}

if CommandLine.arguments.contains("--dock-probe") {
    DockAXProbe.run()
    exit(0)
}

if CommandLine.arguments.contains("--icons-probe") {
    IconTracker.shared.refreshIfNeeded(now: CACurrentMediaTime())
    var out = "trusted=\(IconTracker.shared.trusted) icons=\(IconTracker.shared.icons.count)\n"
    for icon in IconTracker.shared.icons {
        out += "\(icon.title) rect=\(icon.rect) cells=\(icon.profile.count)\n"
    }
    try? out.write(toFile: "/tmp/snow_icons_probe.txt", atomically: true, encoding: .utf8)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
