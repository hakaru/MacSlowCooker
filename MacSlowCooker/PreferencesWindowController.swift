import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {

    private let settings: Settings

    init(settings: Settings = .shared) {
        self.settings = settings
        let view = PreferencesView(settings: settings)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 440))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PreferencesView: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Pot Style", selection: $settings.potStyle) {
                    Text("Dutch Oven").tag(PotStyle.dutchOven)
                }

                Picker("Flame Animation", selection: $settings.flameAnimation) {
                    Text("Off").tag(FlameAnimation.none)
                    Text("Interpolation").tag(FlameAnimation.interpolation)
                    Text("Wiggle").tag(FlameAnimation.wiggle)
                    Text("Both").tag(FlameAnimation.both)
                }
            }

            Section("Boiling Effect") {
                Picker("Trigger", selection: $settings.boilingTrigger) {
                    Text("Temperature ≥ 85°C").tag(BoilingTrigger.temperature)
                    Text("Thermal Pressure ≥ Serious").tag(BoilingTrigger.thermalPressure)
                    Text("Combined (Recommended)").tag(BoilingTrigger.combined)
                }
            }

            Section("Window") {
                Toggle("Float above other windows", isOn: $settings.floatAboveOtherWindows)
            }

            Section("Prometheus Exporter") {
                Toggle("Enable", isOn: $settings.prometheusEnabled)
                Stepper(value: $settings.prometheusPort, in: 1024...65535) {
                    HStack {
                        Text("Port")
                        Spacer()
                        Text("\(settings.prometheusPort)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Bind to all interfaces (allows remote scraping)", isOn: $settings.prometheusBindAll)
                    .disabled(!settings.prometheusEnabled)
                if settings.prometheusEnabled {
                    Text("http://\(settings.prometheusBindAll ? "0.0.0.0" : "127.0.0.1"):\(settings.prometheusPort)/metrics")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Energy") {
                LowPowerStatusRow()
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to defaults") { settings.resetToDefaults() }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// Live readout of `ProcessInfo.isLowPowerModeEnabled`. The animator drops to
/// 5 fps and disables wiggle while LPM is on; surfacing the override here
/// avoids the user wondering why their wiggle setting has no visible effect.
private struct LowPowerStatusRow: View {
    @State private var isOn: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        HStack {
            Image(systemName: isOn ? "leaf.fill" : "leaf")
                .foregroundStyle(isOn ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(isOn ? "Low Power Mode is on" : "Low Power Mode is off")
                    .font(.system(size: 13))
                if isOn {
                    Text("Animation reduced to 5 fps and flame wiggle disabled.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isOn = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}
