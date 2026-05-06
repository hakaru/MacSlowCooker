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
        window.setContentSize(NSSize(width: 420, height: 720))
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
    @State private var draftKey: String = ""
    @State private var isVerifying = false
    @State private var licenseError: String? = nil
    @State private var verifyTask: Task<Void, Never>? = nil

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
                .disabled(!settings.prometheusEnabled)
                Toggle("Bind to all interfaces (allows remote scraping)", isOn: $settings.prometheusBindAll)
                    .disabled(!settings.prometheusEnabled)
                if settings.prometheusEnabled {
                    if settings.prometheusBindAll {
                        Text("http://<this-Mac-IP>:\(settings.prometheusPort)/metrics")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Listens on all interfaces. macOS will prompt to allow incoming connections on first remote access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("http://127.0.0.1:\(settings.prometheusPort)/metrics")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("PNG Export") {
                Toggle("Enable", isOn: $settings.pngExportEnabled)
                HStack {
                    Text("Folder")
                    Spacer()
                    Text(abbreviatedPath(settings.pngExportPath))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                HStack {
                    Spacer()
                    Button("Choose Folder…") { chooseFolder() }
                    Button("Reveal in Finder") { revealInFinder() }
                        .disabled(!FileManager.default.fileExists(atPath: settings.pngExportPath))
                }
                if settings.pngExportEnabled {
                    Text("Re-rendered every 5 minutes. Serve with e.g. `python3 -m http.server -d \"\(settings.pngExportPath)\"`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("License") {
                HStack {
                    TextField("License Key", text: $draftKey)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.plain)
                    if isVerifying {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Button("Verify") {
                            verifyTask?.cancel()
                            verifyTask = Task { await verifyLicense() }
                        }
                        .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let verifiedAt = settings.licenseVerifiedAt,
                   settings.licenseKey == draftKey.trimmingCharacters(in: .whitespaces) {
                    Label(
                        "Verified \(verifiedAt.formatted(date: .abbreviated, time: .omitted))",
                        systemImage: "checkmark.seal.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.caption)
                } else if let error = licenseError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .font(.caption)
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
        .onAppear { draftKey = settings.licenseKey ?? "" }
        .onDisappear { verifyTask?.cancel() }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settings.pngExportPath)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.pngExportPath = url.path
        }
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: settings.pngExportPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func verifyLicense() async {
        let key = draftKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        isVerifying = true
        licenseError = nil
        let validator = LicenseValidator(productPermalink: "fzifrw")
        let result = await validator.verify(key: key)
        isVerifying = false
        guard !Task.isCancelled else { return }
        switch result {
        case .verified:
            settings.licenseKey = key
            settings.licenseVerifiedAt = Date()
        case .invalid(let message):
            settings.licenseVerifiedAt = nil
            licenseError = message
        case .networkError(let message):
            licenseError = "Network error: \(message)"
        }
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
