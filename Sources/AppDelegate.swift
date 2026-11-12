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
    private var season: Season = .snow
    private var snowDensity: SnowDensity = .light
    private var autumnDensity: SnowDensity = .normal
    private var autumnNeverDisappear = false
    private var autumnTiltGravity = false

    private let snowDensityKey = "snow.density"
    private let autumnDensityKey = "autumn.density"
    private let autumnNeverDisappearKey = "autumn.neverDisappear"
    private let autumnTiltGravityKey = "autumn.tiltGravity"
    private let seasonKey = "season.current"
    private let enabledKey = "snow.enabled"
    private let setupKey = "snow.setupComplete"
    private let lightMigrationKey = "snow.defaultLight.v1"

    private var activeDensity: SnowDensity {
        season == .snow ? snowDensity : autumnDensity
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadSettings()
        buildControllers()
        buildStatusItem()
        updateTiltGravity()

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

        if CommandLine.arguments.contains("--preview-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.togglePopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TiltGravity.shared.stop()
        controllers.forEach { $0.close() }
    }

    // MARK: - Settings

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: enabledKey) != nil {
            enabled = defaults.bool(forKey: enabledKey)
        }
        if defaults.object(forKey: seasonKey) != nil,
           let raw = Season(rawValue: defaults.integer(forKey: seasonKey)) {
            season = raw
        }

        if defaults.object(forKey: lightMigrationKey) == nil {
            snowDensity = .light
            defaults.set(true, forKey: lightMigrationKey)
            defaults.set(snowDensity.rawValue, forKey: snowDensityKey)
        } else if defaults.object(forKey: snowDensityKey) != nil,
                  let raw = SnowDensity(rawValue: defaults.integer(forKey: snowDensityKey)) {
            snowDensity = raw
        }

        if defaults.object(forKey: autumnDensityKey) != nil,
           let raw = SnowDensity(rawValue: defaults.integer(forKey: autumnDensityKey)) {
            autumnDensity = raw
        }
        autumnNeverDisappear = defaults.bool(forKey: autumnNeverDisappearKey)
        autumnTiltGravity = defaults.bool(forKey: autumnTiltGravityKey)
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: enabledKey)
        defaults.set(season.rawValue, forKey: seasonKey)
        defaults.set(snowDensity.rawValue, forKey: snowDensityKey)
        defaults.set(autumnDensity.rawValue, forKey: autumnDensityKey)
        defaults.set(autumnNeverDisappear, forKey: autumnNeverDisappearKey)
        defaults.set(autumnTiltGravity, forKey: autumnTiltGravityKey)
    }

    private func buildControllers() {
        controllers.forEach { $0.close() }
        controllers.removeAll()

        let mainHeight = ScreenGeometry.mainHeight
        for screen in NSScreen.screens {
            if let c = ScreenController(screen: screen, mainHeight: mainHeight,
                                        season: season, density: activeDensity) {
                c.setNeverDisappear(autumnNeverDisappear)
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
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
            button.toolTip = "Seasons on Mac"
            button.appearsDisabled = !enabled
        }

        let model = SnowMenuModel(enabled: enabled,
                                  season: season,
                                  snowDensity: snowDensity,
                                  autumnDensity: autumnDensity,
                                  neverDisappear: autumnNeverDisappear,
                                  tiltGravity: autumnTiltGravity,
                                  tiltAvailable: TiltGravity.sensorAvailable(),
                                  axEnabled: AXIsProcessTrusted())
        model.delegate = self
        menuModel = model

        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: SnowMenuView(model: model))
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 300, height: 510)
        self.popover = popover

        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: season.symbol,
                            accessibilityDescription: "Seasons on Mac")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !enabled
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
        ensureEnabled()
        setupWindowController?.close()
    }

    func closeSetup() {
        finishSetup()
    }

    private func setupDidClose() {
        UserDefaults.standard.set(true, forKey: setupKey)
        ensureEnabled()
    }

    private func ensureEnabled() {
        guard !enabled else { return }
        enabled = true
        setVisible(true)
        saveSettings()
        menuModel?.enabled = enabled
        statusItem?.button?.appearsDisabled = false
        updateTiltGravity()
    }

    // MARK: - Actions

    @objc func toggleSnow() {
        enabled.toggle()
        setVisible(enabled)
        menuModel?.enabled = enabled
        statusItem?.button?.appearsDisabled = !enabled
        saveSettings()
        updateTiltGravity()
    }

    private func setVisible(_ visible: Bool) {
        for c in controllers { c.setVisible(visible) }
    }

    func switchSeason(_ newSeason: Season) {
        guard newSeason != season else { return }
        season = newSeason
        saveSettings()
        buildControllers()
        updateStatusIcon()
        menuModel?.season = newSeason
        menuModel?.snowDensity = snowDensity
        menuModel?.autumnDensity = autumnDensity
        menuModel?.neverDisappear = autumnNeverDisappear
        menuModel?.tiltGravity = autumnTiltGravity
        updateTiltGravity()
    }

    func setNeverDisappear(_ value: Bool) {
        autumnNeverDisappear = value
        UserDefaults.standard.set(value, forKey: autumnNeverDisappearKey)
        controllers.forEach { $0.setNeverDisappear(value) }
        menuModel?.neverDisappear = value
    }

    func setTiltGravity(_ value: Bool) {
        autumnTiltGravity = value
        saveSettings()
        menuModel?.tiltGravity = value
        updateTiltGravity()
    }

    private func updateTiltGravity() {
        let shouldRun = autumnTiltGravity && season == .autumn && enabled
        TiltGravity.shared.setEnabled(shouldRun)
    }

    func applyDensity(_ d: SnowDensity) {
        if season == .snow { snowDensity = d } else { autumnDensity = d }
        controllers.forEach { $0.setDensity(d) }
        saveSettings()
        menuModel?.snowDensity = snowDensity
        menuModel?.autumnDensity = autumnDensity
    }

    @objc private func setDensity(_ sender: NSMenuItem) {
        guard let d = SnowDensity(rawValue: sender.tag) else { return }
        applyDensity(d)
    }

    @objc func clearSnow() {
        controllers.forEach { $0.clear() }
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
}
