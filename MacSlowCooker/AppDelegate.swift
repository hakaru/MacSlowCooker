import AppKit
import os.log

private let log = OSLog(subsystem: "com.macslowcooker", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = GPUDataStore()
    private let xpcClient = XPCClient()
    private lazy var popupController = PopupWindowController(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip helper-daemon setup when running under XCTest. Otherwise a failed
        // install raises a modal NSAlert that blocks the run loop and prevents
        // the test runner from establishing a connection.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        updateDockIcon()
        Task {
            do {
                try await HelperInstaller.installIfNeeded()
                connectXPC()
            } catch {
                os_log("Install failed: %{public}s", log: log, type: .error, error.localizedDescription)
                NSApp.activate(ignoringOtherApps: true)
                showError(error.localizedDescription)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        popupController.toggle()
        return false
    }

    private func connectXPC() {
        xpcClient.onSample = { [weak self] sample in
            guard let self else { return }
            store.addSample(sample)
            updateDockIcon()
        }
        xpcClient.onConnected = { [weak self] in
            self?.store.setConnected(true)
            os_log("XPC connected", log: log, type: .info)
        }
        xpcClient.onDisconnected = { [weak self] in
            self?.store.setConnected(false)
            self?.updateDockIcon()
            os_log("XPC disconnected", log: log, type: .info)
        }
        xpcClient.connect()
    }

    private func updateDockIcon() {
        let usage = store.latestSample?.gpuUsage ?? 0
        let connected = store.isConnected
        DispatchQueue.global(qos: .userInteractive).async {
            let image = DockIconRenderer.render(usage: usage, isConnected: connected)
            DispatchQueue.main.async {
                NSApp.applicationIconImage = image
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MacSlowCooker — セットアップエラー"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
