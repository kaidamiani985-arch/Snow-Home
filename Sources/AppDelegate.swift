import AppKit
import ApplicationServices
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [ScreenController] = []
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var menuModel: SnowMenuModel?
    private var setupWindowController: SetupWindowController?

    private var enabled = true
    private var density: SnowDensity = .light

    private let densityKey = "snow.density"
    private let enabledKey = "snow.enabled"
    private let setupKey = "snow.setupComplete"
    private let lightMigrationKey = "snow.defaultLight.v1"

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        if !UserDefaults.standard.bool(forKey: setupKey) {
            DispatchQueue.main.async { [weak self] in
                self?.showSetup()
            }
        }
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

        // New installs (and existing installs updating to this build) start on
        // the quiet Light setting. After that the user's choice is remembered.
        if defaults.object(forKey: lightMigrationKey) == nil {
            density = .light
            defaults.set(true, forKey: lightMigrationKey)
            defaults.set(density.rawValue, forKey: densityKey)
        } else if defaults.object(forKey: densityKey) != nil,
                  let raw = SnowDensity(rawValue: defaults.integer(forKey: densityKey)) {
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

    @objc private func appBecameActive() {
        menuModel?.refreshAccessibility()
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snow on Mac")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Snow on Mac"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
            button.appearsDisabled = !enabled
        }

        let model = SnowMenuModel(enabled: enabled,
                                  density: density,
                                  axEnabled: AXIsProcessTrusted())
        model.delegate = self
        menuModel = model

        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: SnowMenuView(model: model))
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 286, height: 350)
        self.popover = popover

        statusItem = item
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Setup window

    func showSetup() {
        if setupWindowController == nil {
            guard let model = menuModel else { return }
            setupWindowController = SetupWindowController(model: model) { [weak self] in
                self?.setupDidClose()
            }
        }
        setupWindowController?.showWindow(nil)
        setupWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func finishSetup() {
        UserDefaults.standard.set(true, forKey: setupKey)
        ensureSnowEnabled()
        setupWindowController?.close()
    }

    func closeSetup() {
        finishSetup()
    }

    private func setupDidClose() {
        UserDefaults.standard.set(true, forKey: setupKey)
        ensureSnowEnabled()
    }

    private func ensureSnowEnabled() {
        guard !enabled else { return }
        enabled = true
        setVisible(true)
        saveSettings()
        menuModel?.enabled = enabled
        statusItem?.button?.appearsDisabled = false
    }

    // MARK: - Actions

    @objc func toggleSnow() {
        enabled.toggle()
        setVisible(enabled)
        refreshState()
        saveSettings()
    }

    private func setVisible(_ visible: Bool) {
        for c in controllers {
            c.setVisible(visible)
        }
    }

    func applyDensity(_ d: SnowDensity) {
        density = d
        controllers.forEach { $0.setDensity(d) }
        saveSettings()
        menuModel?.density = d
    }

    @objc private func setDensity(_ sender: NSMenuItem) {
        guard let d = SnowDensity(rawValue: sender.tag) else { return }
        applyDensity(d)
    }

    @objc func clearSnow() {
        controllers.forEach { $0.clearSnow() }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func refreshState() {
        menuModel?.enabled = enabled
        statusItem?.button?.appearsDisabled = !enabled
    }
}
