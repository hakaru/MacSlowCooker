import AppKit
import os.log

private let log = OSLog(subsystem: "com.macslowcooker", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = GPUDataStore()
    private let xpcClient = XPCClient()
    private let settings = Settings.shared
    private let animator = DockIconAnimator()

    private lazy var popupController = PopupWindowController(store: store)
    private var preferencesController: PreferencesWindowController?
    private var settingsObservationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip helper-daemon setup when running under XCTest. Otherwise a failed
        // install raises a modal NSAlert that blocks the run loop and prevents
        // the test runner from establishing a connection.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        buildMainMenu()
        observeSettings()
        observeSystemSleep()
        animator.setConnected(false)   // initial Disconnected paint

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
        appMenu.addItem(NSMenuItem(title: "About MacSlowCooker",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Preferences…",
                                   action: #selector(showPreferences),
                                   keyEquivalent: ","))

        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(services)

        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide MacSlowCooker",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All",
                                   action: #selector(NSApplication.unhideAllApplications(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit MacSlowCooker",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom",     action: #selector(NSWindow.performZoom(_:)),        keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
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

    // MARK: - XPC

    private func connectXPC() {
        xpcClient.onSample = { [weak self] sample in
            guard let self else { return }
            store.addSample(sample)
            animator.update(sample: sample)
        }
        xpcClient.onConnected = { [weak self] in
            self?.store.setConnected(true)
            self?.animator.setConnected(true)
            os_log("XPC connected", log: log, type: .info)
        }
        xpcClient.onDisconnected = { [weak self] in
            self?.store.setConnected(false)
            self?.animator.setConnected(false)
            os_log("XPC disconnected", log: log, type: .info)
        }
        xpcClient.connect()
    }

    // MARK: - Settings observation

    private func observeSettings() {
        settingsObservationTask = Task { @MainActor [animator, settings] in
            for await _ in settings.changes {
                animator.settingsDidChange()
            }
        }
    }

    // MARK: - System sleep

    private func observeSystemSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification,        object: nil, queue: .main) { [weak self] _ in self?.animator.setSystemAsleep(true)  }
        nc.addObserver(forName: NSWorkspace.didWakeNotification,          object: nil, queue: .main) { [weak self] _ in self?.animator.setSystemAsleep(false) }
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,  object: nil, queue: .main) { [weak self] _ in self?.animator.setSystemAsleep(true)  }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,   object: nil, queue: .main) { [weak self] _ in self?.animator.setSystemAsleep(false) }
    }

    // MARK: - Error UI

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MacSlowCooker — Setup Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
