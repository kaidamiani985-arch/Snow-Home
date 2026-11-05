import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [ScreenController] = []
    private var statusItem: NSStatusItem?
    private var enabled = true
    private var density: SnowDensity = .normal

    private let densityKey = "snow.density"
    private let enabledKey = "snow.enabled"

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadSettings()
        buildControllers()
        buildStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        controllers.forEach { $0.close() }
    }

    // MARK: - Setup

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: enabledKey) != nil {
            enabled = defaults.bool(forKey: enabledKey)
        }
        if let raw = SnowDensity(rawValue: defaults.integer(forKey: densityKey)) {
            density = raw
        }
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: enabledKey)
        defaults.set(density.rawValue, forKey: densityKey)
    }

    private func buildControllers() {
        controllers.forEach { $0.close() }
        controllers.removeAll()

        let mainHeight = ScreenGeometry.mainHeight
        for screen in NSScreen.screens {
            if let c = ScreenController(screen: screen, mainHeight: mainHeight, density: density) {
                controllers.append(c)
            }
        }

        if !enabled { setVisible(false) }
    }

    @objc private func screensChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.buildControllers()
        }
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snow")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Snow on Mac"
        }

        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Snowfall", action: #selector(toggleSnow), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        let densityItem = NSMenuItem(title: "Density", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for d in SnowDensity.allCases {
            let mi = NSMenuItem(title: d.label, action: #selector(setDensity(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = d.rawValue
            mi.state = (d == density) ? .on : .off
            submenu.addItem(mi)
        }
        densityItem.submenu = submenu
        menu.addItem(densityItem)

        menu.addItem(NSMenuItem.separator())

        let clear = NSMenuItem(title: "Clear Snow", action: #selector(clearSnow), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit Snow", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func refreshMenuStates() {
        guard let menu = statusItem?.menu else { return }
        for item in menu.items {
            if item.action == #selector(toggleSnow) {
                item.state = enabled ? .on : .off
            }
            if let sub = item.submenu, item.title == "Density" {
                for mi in sub.items {
                    mi.state = (mi.tag == density.rawValue) ? .on : .off
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleSnow() {
        enabled.toggle()
        setVisible(enabled)
        refreshMenuStates()
        saveSettings()
    }

    private func setVisible(_ visible: Bool) {
        for c in controllers {
            c.setVisible(visible)
        }
    }

    @objc private func setDensity(_ sender: NSMenuItem) {
        guard let d = SnowDensity(rawValue: sender.tag) else { return }
        density = d
        controllers.forEach { $0.setDensity(d) }
        refreshMenuStates()
        saveSettings()
    }

    @objc private func clearSnow() {
        controllers.forEach { $0.clearSnow() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
