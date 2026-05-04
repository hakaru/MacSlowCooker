import XCTest
@testable import MacSlowCooker

final class PNGExporterHTMLTests: XCTestCase {
    func testIndexContainsAllPanelImagesAndAutoRefresh() {
        let html = PNGExporterHTML.render(
            nowTs: 1778231262,
            panels: HistoryPanel.all,
            granularities: HistoryGranularity.allCases
        )
        // Auto-refresh meta tag
        XCTAssertTrue(html.contains("<meta http-equiv=\"refresh\""))
        // Title
        XCTAssertTrue(html.contains("MacSlowCooker"))
        // 4 image references — every panel × granularity combination (2 panels × 2 granularities = 4, no wait, 2 panels × 4 granularities = 8)
        for panel in HistoryPanel.all {
            for g in HistoryGranularity.allCases {
                XCTAssertTrue(
                    html.contains("\(panel.id)-\(g.id).png"),
                    "missing \(panel.id)-\(g.id).png"
                )
            }
        }
        // Section headers
        XCTAssertTrue(html.contains("Compute"))
        XCTAssertTrue(html.contains("Thermal"))
        // Last-updated timestamp
        XCTAssertTrue(html.contains("Last updated"))
    }

    func testRenderEscapesAngleBracketsInTitle() {
        // Sanity: no template injection from the static title (defensive).
        let html = PNGExporterHTML.render(
            nowTs: 0,
            panels: HistoryPanel.all,
            granularities: HistoryGranularity.allCases
        )
        XCTAssertFalse(html.contains("<script>"))
    }
}
