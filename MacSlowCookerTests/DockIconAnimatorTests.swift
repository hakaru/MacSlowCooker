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
                        thermalPressure: ThermalPressure? = nil) -> GPUSample {
        GPUSample(timestamp: clock.now,
                  gpuUsage: usage,
                  temperature: temperature,
                  thermalPressure: thermalPressure,
                  power: nil, anePower: nil, aneUsage: nil, fanRPM: nil)
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

    // MARK: - Wiggle

    func testWiggleAdvancesWhenEnabled() {
        settings.flameAnimation = .wiggle
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5))

        let phaseBefore = CapturingRenderer.captured.last!.flameWigglePhase
        clock.advance(by: 0.1)
        animator.tickForTesting()
        let phaseAfter = CapturingRenderer.captured.last!.flameWigglePhase

        XCTAssertNotEqual(phaseBefore, phaseAfter)
        XCTAssertTrue(CapturingRenderer.captured.last!.flameWiggleEnabled)
    }

    func testWiggleStaysWhenDisabled() {
        settings.flameAnimation = .interpolation
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5))

        for _ in 0..<5 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        let last = CapturingRenderer.captured.last!
        XCTAssertEqual(last.flameWigglePhase, 0, accuracy: 1e-9)
        XCTAssertFalse(last.flameWiggleEnabled)
    }

    // MARK: - Boiling fade

    func testBoilingFadesIn() {
        settings.boilingTrigger = .temperature
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5, temperature: 90))

        for _ in 0..<10 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }

        let last = CapturingRenderer.captured.last!
        XCTAssertTrue(last.isBoiling)
        XCTAssertGreaterThan(last.boilingIntensity, 0.8)
    }

    func testBoilingFadesOut() {
        settings.boilingTrigger = .temperature
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5, temperature: 90))
        for _ in 0..<10 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        XCTAssertGreaterThan(CapturingRenderer.captured.last!.boilingIntensity, 0.8)

        animator.update(sample: sample(usage: 0.5, temperature: 60))
        for _ in 0..<15 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        let last = CapturingRenderer.captured.last!
        XCTAssertFalse(last.isBoiling)
        XCTAssertLessThan(last.boilingIntensity, 0.2)
    }

    func testCombinedTrigger5sPersistence() {
        settings.boilingTrigger = .combined
        let animator = makeAnimator()
        animator.setConnected(true)

        // 4.9s of high usage → not boiling
        animator.update(sample: sample(usage: 0.95))
        clock.advance(by: 4.9)
        animator.update(sample: sample(usage: 0.95))
        animator.tickForTesting()
        XCTAssertFalse(CapturingRenderer.captured.last!.isBoiling)

        // Push past 5s
        clock.advance(by: 0.3)
        animator.update(sample: sample(usage: 0.95))
        animator.tickForTesting()
        XCTAssertTrue(CapturingRenderer.captured.last!.isBoiling)
    }

    // MARK: - Timer lifecycle

    func testIdleAnimatorStopsTimer() {
        settings.flameAnimation = .none
        let animator = DockIconAnimator(settings: settings,
                                        renderer: CapturingRenderer.self,
                                        clock: clock,
                                        autostartTimer: true)
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0))

        // Drive simulated ticks until interpolation converges
        for _ in 0..<30 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        XCTAssertFalse(animator.isTimerRunningForTesting)
    }

    func testWiggleKeepsTimerRunning() {
        settings.flameAnimation = .wiggle
        let animator = DockIconAnimator(settings: settings,
                                        renderer: CapturingRenderer.self,
                                        clock: clock,
                                        autostartTimer: true)
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5))

        for _ in 0..<30 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        XCTAssertTrue(animator.isTimerRunningForTesting)
    }

    // MARK: - System sleep

    func testSystemSleepStopsTimer() {
        settings.flameAnimation = .both
        let animator = DockIconAnimator(settings: settings,
                                        renderer: CapturingRenderer.self,
                                        clock: clock,
                                        autostartTimer: true)
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5))
        XCTAssertTrue(animator.isTimerRunningForTesting)

        animator.setSystemAsleep(true)
        XCTAssertFalse(animator.isTimerRunningForTesting)
    }

    func testSystemWakeRestartsAnimation() {
        settings.flameAnimation = .both
        let animator = DockIconAnimator(settings: settings,
                                        renderer: CapturingRenderer.self,
                                        clock: clock,
                                        autostartTimer: true)
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5))
        animator.setSystemAsleep(true)
        XCTAssertFalse(animator.isTimerRunningForTesting)

        animator.setSystemAsleep(false)
        XCTAssertTrue(animator.isTimerRunningForTesting)
    }

    // MARK: - Disconnect / reconnect

    func testDisconnectResetsBoiling() {
        settings.boilingTrigger = .temperature
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5, temperature: 90))
        animator.tickForTesting()
        XCTAssertTrue(CapturingRenderer.captured.last!.isBoiling)

        animator.setConnected(false)
        animator.tickForTesting()
        XCTAssertFalse(CapturingRenderer.captured.last!.isBoiling)
    }

    func testReconnectRestartsCombinedTimer() {
        settings.boilingTrigger = .combined
        let animator = makeAnimator()

        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.95))
        XCTAssertNotNil(animator.aboveThresholdSinceForTesting)

        animator.setConnected(false)
        XCTAssertNil(animator.aboveThresholdSinceForTesting)

        clock.advance(by: 30)
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.95))
        XCTAssertEqual(animator.aboveThresholdSinceForTesting, clock.now)
    }

    // MARK: - Settings change

    func testSettingsChangeResetsCombinedTimerWhenSwitchingMode() {
        settings.boilingTrigger = .combined
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.95))
        XCTAssertNotNil(animator.aboveThresholdSinceForTesting)

        settings.boilingTrigger = .temperature
        animator.settingsDidChange()
        XCTAssertNil(animator.aboveThresholdSinceForTesting)
    }

    // MARK: - Visual hash dedup

    func testNoRenderWhenStateUnchanged() {
        settings.flameAnimation = .none
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0))

        // Drive ticks until convergence
        for _ in 0..<60 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        let calls1 = CapturingRenderer.captured.count

        // Several more ticks at the same steady state
        for _ in 0..<10 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        let calls2 = CapturingRenderer.captured.count

        XCTAssertEqual(calls1, calls2, "renderer should be skipped when state is unchanged")
    }
}
