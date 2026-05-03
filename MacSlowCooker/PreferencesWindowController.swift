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
        window.setContentSize(NSSize(width: 420, height: 240))
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
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
