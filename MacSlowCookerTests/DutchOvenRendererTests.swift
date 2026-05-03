import XCTest
import AppKit
@testable import MacSlowCooker

final class DutchOvenRendererTests: XCTestCase {

    private func state(usage: Double = 0,
                       isConnected: Bool = true,
                       boilingIntensity: Double = 0,
                       wiggleEnabled: Bool = false) -> IconState {
        IconState(displayedUsage: usage,
                  temperature: 50,
                  isConnected: isConnected,
                  flameWigglePhase: 1.23,
                  flameWiggleEnabled: wiggleEnabled,
                  isBoiling: boilingIntensity > 0,
                  boilingIntensity: boilingIntensity,
                  fanRPM: nil)
    }

    func testProducesNonEmptyImageForRepresentativeStates() {
        let states: [IconState] = [
            state(usage: 0,    isConnected: false),               // Disconnected
            state(usage: 0.05),                                   // Idle
            state(usage: 0.45),                                   // Simmer
            state(usage: 0.75, wiggleEnabled: true),              // High + wiggle
            state(usage: 0.95, boilingIntensity: 1.0)             // Boiling
        ]

        for s in states {
            let img = DutchOvenRenderer.render(state: s)
            XCTAssertEqual(img.size, DutchOvenRenderer.iconSize)
            XCTAssertFalse(img.representations.isEmpty,
                           "renderer must produce a bitmap rep for \(s)")
        }
    }

    func testDoesNotCrashOnExtremes() {
        for u in stride(from: 0.0, through: 1.0, by: 0.05) {
            for connected in [true, false] {
                for boiling in [0.0, 0.5, 1.0] {
                    let s = state(usage: u,
                                  isConnected: connected,
                                  boilingIntensity: boiling,
                                  wiggleEnabled: true)
                    _ = DutchOvenRenderer.render(state: s)
                }
            }
        }
    }
}
