import XCTest
@testable import MacSlowCooker

final class DockIconRendererTests: XCTestCase {

    func testRendersImageForZeroUsage() {
        let image = DockIconRenderer.render(usage: 0.0, isConnected: true)
        XCTAssertEqual(image.size.width, 512)
        XCTAssertEqual(image.size.height, 512)
    }

    func testRendersImageForFullUsage() {
        let image = DockIconRenderer.render(usage: 1.0, isConnected: true)
        XCTAssertEqual(image.size.width, 512)
    }

    func testRendersDisconnectedState() {
        let image = DockIconRenderer.render(usage: 0.5, isConnected: false)
        XCTAssertEqual(image.size.width, 512)
    }
}
