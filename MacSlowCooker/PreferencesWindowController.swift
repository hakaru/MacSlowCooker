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
        window.title = "MacSlowCooker 設定"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 380, height: 220))
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
            Picker("鍋スタイル", selection: $settings.potStyle) {
                Text("ダッチオーブン").tag(PotStyle.dutchOven)
            }

            Picker("炎アニメーション", selection: $settings.flameAnimation) {
                Text("なし").tag(FlameAnimation.none)
                Text("補間のみ").tag(FlameAnimation.interpolation)
                Text("ゆらぎのみ").tag(FlameAnimation.wiggle)
                Text("両方").tag(FlameAnimation.both)
            }

            Picker("沸騰トリガー", selection: $settings.boilingTrigger) {
                Text("温度 ≥ 85°C").tag(BoilingTrigger.temperature)
                Text("熱ストレス ≥ Serious").tag(BoilingTrigger.thermalPressure)
                Text("組み合わせ（推奨）").tag(BoilingTrigger.combined)
            }
        }
        .padding(20)
        .formStyle(.grouped)
    }
}
