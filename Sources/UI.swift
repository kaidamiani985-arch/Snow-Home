import AppKit
import ApplicationServices
import SwiftUI

/// Bridges the SwiftUI controls to the AppKit app delegate.
final class SnowMenuModel: ObservableObject {
    @Published var enabled: Bool
    @Published var season: Season
    @Published var snowDensity: SnowDensity
    @Published var autumnDensity: SnowDensity
    @Published var neverDisappear: Bool
    @Published var tiltGravity: Bool
    @Published var tiltAvailable: Bool
    @Published var axEnabled: Bool
    weak var delegate: AppDelegate?

    init(enabled: Bool, season: Season, snowDensity: SnowDensity,
         autumnDensity: SnowDensity, neverDisappear: Bool,
         tiltGravity: Bool, tiltAvailable: Bool, axEnabled: Bool) {
        self.enabled = enabled
        self.season = season
        self.snowDensity = snowDensity
        self.autumnDensity = autumnDensity
        self.neverDisappear = neverDisappear
        self.tiltGravity = tiltGravity
        self.tiltAvailable = tiltAvailable
        self.axEnabled = axEnabled
    }

    var activeDensity: SnowDensity {
        season == .snow ? snowDensity : autumnDensity
    }

    func toggle() { delegate?.toggleSnow() }
    func setSeason(_ s: Season) { delegate?.switchSeason(s) }
    func setDensity(_ d: SnowDensity) { delegate?.applyDensity(d) }
    func setNeverDisappear(_ value: Bool) { delegate?.setNeverDisappear(value) }
    func setTiltGravity(_ value: Bool) { delegate?.setTiltGravity(value) }
    func clear() { delegate?.clearSnow() }
    func quit() { delegate?.quit() }
    func openSetup() { delegate?.showSetup() }
    func openAccessibility() { delegate?.openAccessibilitySettings() }
    func refreshAccessibility() { axEnabled = AXIsProcessTrusted() }
    func finishSetup() { delegate?.finishSetup() }
    func closeSetup() { delegate?.closeSetup() }
    func showAbout() { delegate?.showAbout() }
}

// MARK: - Menu bar popover

struct SnowMenuView: View {
    @ObservedObject var model: SnowMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            Divider()
            seasonRow
            toggleRow
            densityRow
            if model.season == .autumn {
                Toggle(isOn: Binding(
                    get: { model.neverDisappear },
                    set: { model.setNeverDisappear($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Leaves never disappear")
                            .font(.system(size: 11.5, weight: .medium))
                        Text("Eventually fills the screen")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: Binding(
                    get: { model.tiltGravity },
                    set: { model.setTiltGravity($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Tilt gravity")
                            .font(.system(size: 11.5, weight: .medium))
                        Text(model.tiltAvailable
                             ? "Tilt your Mac to shift the leaves"
                             : "Motion sensor not available")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!model.tiltAvailable)
            }
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
                Text("Seasons on Mac")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("Desktop weather")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(appVersion)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var seasonRow: some View {
        HStack(spacing: 7) {
            ForEach(Season.allCases, id: \.rawValue) { s in
                Button {
                    model.setSeason(s)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: s.symbol)
                            .font(.system(size: 11.5, weight: .medium))
                        Text(s.label)
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(model.season == s
                                  ? Color(red: 0.32, green: 0.52, blue: 0.95).opacity(0.28)
                                  : Color.white.opacity(0.045))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(model.season == s
                                    ? Color(red: 0.45, green: 0.65, blue: 1.0).opacity(0.65)
                                    : Color.white.opacity(0.06),
                                    lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var toggleRow: some View {
        Toggle(isOn: Binding(
            get: { model.enabled },
            set: { _ in model.toggle() }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Weather")
                    .font(.system(size: 12.5, weight: .medium))
                Text(model.enabled ? "On" : "Paused")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var densityRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Density")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { model.activeDensity },
                set: { model.setDensity($0) }
            )) {
                ForEach(SnowDensity.allCases, id: \.rawValue) { d in
                    Text(d.label).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.activeDensity.subtitle(for: model.season))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var actionRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            menuButton("Clear \(model.season.label)", icon: "wind") { model.clear() }
            menuButton("Welcome to Seasons…", icon: "sparkles") { model.openSetup() }
            menuButton("Accessibility Settings…", icon: "hand.raised") { model.openAccessibility() }
            menuButton("About Seasons on Mac", icon: "info.circle") { model.showAbout() }
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
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
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
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Text("Snow in winter. Leaves in autumn. More seasons are on the way.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("Season")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 8) {
                    ForEach(Season.allCases, id: \.rawValue) { s in
                        seasonCard(s)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Density")
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: Binding(
                    get: { model.activeDensity },
                    set: { model.setDensity($0) }
                )) {
                    ForEach(SnowDensity.allCases, id: \.rawValue) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("\(model.activeDensity.subtitle(for: model.season)). You can change this later from the menu bar.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Toggle("Snow and leaves on desktop icons", isOn: Binding(
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

            Spacer(minLength: 4)

            HStack {
                Button("Not Now") { model.closeSetup() }
                    .buttonStyle(.bordered)
                Spacer()
                Button(startLabel) { model.finishSetup() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }

            Text("You can reopen this from the season menu.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 500, height: 500)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.985)
        .onAppear {
            model.refreshAccessibility()
            withAnimation(.easeOut(duration: 0.45)) {
                appeared = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text("Seasons on Mac")
                    .font(.system(size: 19, weight: .semibold))
                Text("A little weather for your desktop")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func seasonCard(_ s: Season) -> some View {
        Button {
            model.setSeason(s)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: s.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(model.season == s
                                     ? Color(red: 0.55, green: 0.74, blue: 1.0)
                                     : Color.secondary)
                Text(s.label)
                    .font(.system(size: 12, weight: .semibold))
                Text(s.tagline)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(model.season == s
                          ? Color(red: 0.32, green: 0.52, blue: 0.95).opacity(0.20)
                          : Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(model.season == s
                            ? Color(red: 0.45, green: 0.65, blue: 1.0).opacity(0.65)
                            : Color.white.opacity(0.06),
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var startLabel: String {
        model.season == .snow ? "Start Snowfall" : "Start Autumn"
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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Seasons on Mac"
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
