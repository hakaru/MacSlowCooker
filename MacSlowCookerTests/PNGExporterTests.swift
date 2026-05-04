import XCTest
@testable import MacSlowCooker

@MainActor
final class PNGExporterTests: XCTestCase {
    func testRenderProducesEightPNGsAndIndexHTML() async throws {
        // Seed an in-memory store with one 5-min row so the renderer has
        // something non-empty to draw.
        let store = try HistoryStore(path: ":memory:")
        try store.insert(
            HistoryRecord(ts: Int(Date().timeIntervalSince1970) - 300,
                          gpuPct: 42, socTempC: 50, powerW: 8, fanRPM: 1500),
            granularity: .fiveMin
        )

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let exporter = PNGExporter(store: store)
        try await exporter.renderOnce(to: dir)

        // 8 PNGs: 2 panels × 4 granularities.
        for panel in HistoryPanel.all {
            for g in HistoryGranularity.allCases {
                let url = dir.appendingPathComponent("\(panel.id)-\(g.id).png")
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                              "missing \(url.lastPathComponent)")
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                XCTAssertGreaterThan(size, 256, "\(url.lastPathComponent) suspiciously small (\(size) bytes)")
            }
        }
        // index.html
        let index = dir.appendingPathComponent("index.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path))
        let body = try String(contentsOf: index, encoding: .utf8)
        XCTAssertTrue(body.contains("compute-daily.png"))
        XCTAssertTrue(body.contains("thermal-yearly.png"))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSlowCookerPNGTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
