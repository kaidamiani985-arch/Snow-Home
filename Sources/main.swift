import AppKit

if CommandLine.arguments.contains("--ax-probe") {
    AXProbe.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
