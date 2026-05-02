import XCTest
@testable import MacSlowCooker

@MainActor
final class DockIconAnimatorTests: XCTestCase {

    private var defaults: UserDefaults!
    private var settings: Settings!
    private var clock: TestClock!
    private let suiteName = "com.macslowcooker.tests.animator"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
        settings = Settings(defaults: defaults)
        clock = TestClock()
        CapturingRenderer.reset()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeAnimator() -> DockIconAnimator {
        DockIconAnimator(settings: settings,
                         renderer: CapturingRenderer.self,
                         clock: clock,
                         autostartTimer: false)
    }

    private func sample(usage: Double = 0,
                        temperature: Double? = nil,
                        thermalPressure: String? = nil) -> GPUSample {
        GPUSample(timestamp: clock.now,
                  gpuUsage: usage,
                  temperature: temperature,
                  thermalPressure: thermalPressure,
                  power: nil, anePower: nil, aneUsage: nil)
    }

    // MARK: - Interpolation

    func testInterpolationProgressesTowardsTarget() {
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 1.0))

        // Drive 10 ticks of 100 ms each
        for _ in 0..<10 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }

        let last = CapturingRenderer.captured.last!
        // 1 - exp(-1.0 / 0.7) ≈ 0.76
        XCTAssertGreaterThan(last.displayedUsage, 0.70)
        XCTAssertLessThan(last.displayedUsage, 0.82)
    }

    func testInterpolationConvergesAtSteadyState() {
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5))

        for _ in 0..<60 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }

        let last = CapturingRenderer.captured.last!
        XCTAssertEqual(last.displayedUsage, 0.5, accuracy: 0.01)
    }
}
