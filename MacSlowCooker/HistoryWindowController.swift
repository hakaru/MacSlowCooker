import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController: NSWindowController {
    private let model: HistoryViewModel

    init(store: HistoryStore) {
        let model = HistoryViewModel(store: store)
        self.model = model

        let host = NSHostingController(rootView: HistoryView(model: model))
        let w = NSWindow(contentViewController: host)
        w.title = "MacSlowCooker — History"
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 560, height: 860))
        w.center()
        w.isReleasedWhenClosed = false

        super.init(window: w)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in await model.reload() }
    }
}
