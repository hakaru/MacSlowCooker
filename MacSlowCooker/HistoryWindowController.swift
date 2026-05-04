import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private let model: HistoryViewModel

    init(store: HistoryStore) {
        self.model = HistoryViewModel(store: store)
    }

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            model.reload()
            return
        }
        let host = NSHostingController(rootView: HistoryView(model: model))
        let w = NSWindow(contentViewController: host)
        w.title = "MacSlowCooker — History"
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 560, height: 600))
        w.center()
        w.isReleasedWhenClosed = false
        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
