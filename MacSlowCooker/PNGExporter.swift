import AppKit
import SwiftUI
import os

/// Periodically renders the MRTG-style history panels off-screen and writes
/// them to disk as PNG files plus an `index.html`. Off by default; toggled
/// via Preferences. The output directory is meant to be served by the user's
/// own static web server (`python3 -m http.server -d <path>` etc.).
@MainActor
final class PNGExporter {
    private let store: HistoryStore
    private let log = OSLog(subsystem: "com.macslowcooker.app", category: "PNGExporter")
    private var timer: Timer?

    /// Five-minute cadence — matches the finest history granularity, so each
    /// render captures every new bucket exactly once.
    private let interval: TimeInterval = 300

    init(store: HistoryStore) { self.store = store }

    /// Begin periodic rendering into `directory`. Creates the directory if
    /// it doesn't exist, fires one render immediately, then re-renders every
    /// 5 minutes. Idempotent — calling start again replaces the previous timer.
    func start(at directory: URL) {
        stop()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            os_log("createDirectory failed: %{public}@", log: log, type: .error, "\(error)")
            return
        }
        // Fire-and-forget the first render so the directory isn't empty.
        Task { @MainActor [weak self] in
            try? await self?.renderOnce(to: directory)
        }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                try? await self?.renderOnce(to: directory)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Render the current snapshot into `directory`, overwriting any existing
    /// files. One render = 8 PNGs + 1 index.html. Public for tests.
    func renderOnce(to directory: URL) async throws {
        let nowTs = Int(Date().timeIntervalSince1970)
        var byGranularity: [HistoryGranularity: [HistoryRecord]] = [:]
        for g in HistoryGranularity.allCases {
            let since = nowTs - g.retentionSeconds
            byGranularity[g] = (try? store.query(granularity: g, sinceTs: since, untilTs: nowTs)) ?? []
        }

        for panel in HistoryPanel.all {
            for g in HistoryGranularity.allCases {
                let view = MRTGGraphView(
                    records: byGranularity[g] ?? [],
                    panel: panel,
                    granularity: g,
                    nowTs: nowTs
                )
                .frame(width: 600, height: 140)

                let renderer = ImageRenderer(content: view)
                renderer.scale = 2  // retina

                guard let cgImage = renderer.cgImage else {
                    os_log("ImageRenderer returned nil for %{public}@-%{public}@",
                           log: log, type: .error, panel.id, g.id)
                    continue
                }
                let bmp = NSBitmapImageRep(cgImage: cgImage)
                guard let png = bmp.representation(using: .png, properties: [:]) else {
                    os_log("PNG encode failed for %{public}@-%{public}@",
                           log: log, type: .error, panel.id, g.id)
                    continue
                }
                let url = directory.appendingPathComponent("\(panel.id)-\(g.id).png")
                try png.write(to: url, options: .atomic)
            }
        }

        // index.html
        let html = PNGExporterHTML.render(
            nowTs: nowTs,
            panels: HistoryPanel.all,
            granularities: HistoryGranularity.allCases
        )
        let indexURL = directory.appendingPathComponent("index.html")
        try Data(html.utf8).write(to: indexURL, options: .atomic)
    }
}
