import AppKit
import SwiftUI

@MainActor
final class PopupWindowController: NSWindowController {

    private weak var store: GPUDataStore?
    private var globalEventMonitor: Any?

    convenience init(store: GPUDataStore) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true

        self.init(window: panel)
        self.store = store

        let hostingView = NSHostingView(rootView: PopupView(store: store))
        hostingView.frame = panel.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hostingView)
    }

    func toggle() {
        if window?.isVisible == true {
            close()
        } else {
            showPopup()
        }
    }

    override func close() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        window?.orderOut(nil)
    }

    private func showPopup() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = window!.frame.size

        // Position above Dock (bottom-center of visible frame)
        let x = screenFrame.midX - windowSize.width / 2
        let y = screenFrame.minY + 8
        window?.setFrameOrigin(NSPoint(x: x, y: y))
        window?.makeKeyAndOrderFront(nil)

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, let win = self.window, win.isVisible else { return }
            // Use screen coordinates (NSEvent.mouseLocation) to test containment
            if !win.frame.contains(NSEvent.mouseLocation) {
                DispatchQueue.main.async { self.close() }
            }
        }
    }
}
