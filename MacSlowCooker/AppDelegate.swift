import AppKit
import os.log

private let log = OSLog(subsystem: "com.macslowcooker", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = GPUDataStore()
    private let xpcClient = XPCClient()
    private lazy var popupController = PopupWindowController(store: store)
    private var preferencesController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip helper-daemon setup when running under XCTest. Otherwise a failed
        // install raises a modal NSAlert that blocks the run loop and prevents
        // the test runner from establishing a connection.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        buildMainMenu()
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

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "MacSlowCooker について",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "設定…",
                                   action: #selector(showPreferences),
                                   keyEquivalent: ","))

        let services = NSMenuItem(title: "サービス", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(services)

        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "MacSlowCooker を隠す",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: "ほかを隠す",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "すべてを表示",
                                   action: #selector(NSApplication.unhideAllApplications(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "MacSlowCooker を終了",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu — required for Cmd-C/V/X/A in Preferences
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(NSMenuItem(title: "取り消す",  action: Selector(("undo:")),       keyEquivalent: "z"))
        let redo = NSMenuItem(title: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "カット", action: #selector(NSText.cut(_:)),    keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "コピー", action: #selector(NSText.copy(_:)),   keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "すべて選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Window menu
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウィンドウ")
        windowMenu.addItem(NSMenuItem(title: "しまう",
                                      action: #selector(NSWindow.performMiniaturize(_:)),
                                      keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "拡大/縮小",
                                      action: #selector(NSWindow.performZoom(_:)),
                                      keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "すべてを手前に移動",
                                      action: #selector(NSApplication.arrangeInFront(_:)),
                                      keyEquivalent: ""))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showPreferences() {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController()
        }
        preferencesController?.showWindow()
    }

    // MARK: - XPC (kept from previous version, will be replaced in Task 13)

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
