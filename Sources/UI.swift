import AppKit
import ApplicationServices
import SwiftUI

extension SnowDensity {
    var subtitle: String {
        switch self {
        case .light: return "A quiet dusting"
        case .normal: return "A steady fall"
        case .heavy: return "A proper blizzard"
        }
    }
}

/// Bridges the SwiftUI controls to the AppKit app delegate.
final class SnowMenuModel: ObservableObject {
    @Published var enabled: Bool
    @Published var density: SnowDensity
    @Published var axEnabled: Bool
    weak var delegate: AppDelegate?

    init(enabled: Bool, density: SnowDensity, axEnabled: Bool) {
        self.enabled = enabled
        self.density = density
        self.axEnabled = axEnabled
    }

    func toggle() { delegate?.toggleSnow() }
    func setDensity(_ d: SnowDensity) { delegate?.applyDensity(d) }
    func clear() { delegate?.clearSnow() }
    func quit() { delegate?.quit() }
    func openSetup() { delegate?.showSetup() }
    func openAccessibility() { delegate?.openAccessibilitySettings() }
    func showAbout() { delegate?.showAbout() }
    func refreshAccessibility() { axEnabled = AXIsProcessTrusted() }
    func finishSetup() { delegate?.finishSetup() }
    func closeSetup() { delegate?.closeSetup() }
}

// MARK: - Menu bar popover

struct SnowMenuView: View {
    @ObservedObject var model: SnowMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            toggleRow
            densityRow
            Divider()
            actionRows
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 286)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Snow on Mac")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("Desktop snowfall")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("0.1.0")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var toggleRow: some View {
        Toggle(isOn: Binding(
            get: { model.enabled },
            set: { _ in model.toggle() }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Snowfall")
                    .font(.system(size: 12.5, weight: .medium))
                Text(model.enabled ? "Falling" : "Paused")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var densityRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Density")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { model.density },
                set: { model.setDensity($0) }
            )) {
                ForEach(SnowDensity.allCases, id: \.rawValue) { d in
                    Text(d.label).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var actionRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            menuButton("Clear Snow", icon: "wind") { model.clear() }
            menuButton("Welcome to Snow…", icon: "sparkles") { model.openSetup() }
            menuButton("Accessibility Settings…", icon: "hand.raised") { model.openAccessibility() }
            menuButton("About Snow on Mac", icon: "info.circle") { model.showAbout() }
        }
    }

    private var footer: some View {
        HStack {
            Text("Made with Swift + Metal")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { model.quit() }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5, weight: .medium))
        }
    }

    private func menuButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var appIcon: NSImage {
        NSApp.applicationIconImage
            ?? NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)
            ?? NSImage()
    }
}

// MARK: - First-run setup

struct SetupView: View {
    @ObservedObject var model: SnowMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Text("Snow settles on your windows, the Dock, and desktop icons. Push it with your cursor, or shake a window to let it fall.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("Snowfall")
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: Binding(
                    get: { model.density },
                    set: { model.setDensity($0) }
                )) {
                    ForEach(SnowDensity.allCases, id: \.rawValue) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("\(model.density.subtitle). You can change this later from the menu bar.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Toggle("Snow on desktop icons", isOn: Binding(
                    get: { model.axEnabled },
                    set: { on in if on { model.openAccessibility() } }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .disabled(model.axEnabled)

                Text(model.axEnabled
                     ? "Accessibility access is enabled."
                     : "Requires Accessibility access. The rest of the app works without it.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                if !model.axEnabled {
                    Button("Open System Settings…") { model.openAccessibility() }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))
                }
            }

            Spacer(minLength: 6)

            HStack {
                Button("Not Now") { model.closeSetup() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Start Snowfall") { model.finishSetup() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }

            Text("You can reopen this from the snowflake menu.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(22)
        .frame(width: 500, height: 390)
        .onAppear { model.refreshAccessibility() }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text("Snow on Mac")
                    .font(.system(size: 19, weight: .semibold))
                Text("Desktop snowfall for macOS")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var appIcon: NSImage {
        NSApp.applicationIconImage
            ?? NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)
            ?? NSImage()
    }
}

// MARK: - Setup window

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(model: SnowMenuModel, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Snow on Mac"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.contentViewController = NSHostingController(rootView: SetupView(model: model))
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
