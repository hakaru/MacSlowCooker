import AppKit
import SwiftUI

/// Activity Monitor's "GPU の履歴" style window: a regular activatable
/// NSWindow with a title bar, movable and resizable, that floats above
/// other apps. Clicking the Dock icon toggles its visibility; once open,
/// the user can move/resize it freely. Closing returns to hidden state.
@MainActor
final class PopupWindowController: NSWindowController, NSWindowDelegate {

    private weak var store: GPUDataStore?
    private var settings: Settings = .shared
    private var settingsTask: Task<Void, Never>?

    convenience init(store: GPUDataStore, settings: Settings = .shared) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacSlowCooker"
        window.isMovableByWindowBackground = true
        // Use contentMinSize so the title bar isn't part of the constraint —
        // window.minSize includes the title bar and lets content shrink below
        // the SwiftUI minimum.
        window.contentMinSize = NSSize(width: 760, height: 320)
        window.isReleasedWhenClosed = false

        self.init(window: window)
        self.store = store
        self.settings = settings
        window.delegate = self

        let hostingView = NSHostingView(rootView: PopupView(store: store))
        hostingView.frame = window.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hostingView)

        applyWindowLevel()
        observeSettings()
    }

    deinit {
        settingsTask?.cancel()
    }

    func toggle() {
        if window?.isVisible == true {
            close()
        } else {
            showPopup()
        }
    }

    private func showPopup() {
        guard let win = window else { return }

        // Position above the Dock on first show; subsequent shows reuse the
        // user's last position.
        if !win.isOnActiveSpace || win.frame.origin == .zero {
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                let size = win.frame.size
                win.setFrameOrigin(NSPoint(
                    x: frame.midX - size.width / 2,
                    y: frame.minY + 8))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Apply the user's "Float above other windows" preference. When ON the
    /// popup uses `.floating` and joins all spaces / fullscreen overlays,
    /// matching legacy behavior. When OFF the popup acts like a normal
    /// window — better for users who want it in the standard window order.
    private func applyWindowLevel() {
        guard let win = window else { return }
        if settings.floatAboveOtherWindows {
            win.level = .floating
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            win.level = .normal
            win.collectionBehavior = []
        }
    }

    private func observeSettings() {
        settingsTask?.cancel()
        let stream = settings.changes
        settingsTask = Task { @MainActor [weak self] in
            for await _ in stream {
                self?.applyWindowLevel()
            }
        }
    }

    // MARK: - NSWindowDelegate

    /// Hide rather than destroy on close so we can reopen with state preserved.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
