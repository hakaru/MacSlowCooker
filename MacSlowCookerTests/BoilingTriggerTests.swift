import XCTest
@testable import MacSlowCooker

final class BoilingTriggerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(usage: Double = 0,
                        temperature: Double? = nil,
                        thermalPressure: String? = nil) -> GPUSample {
        GPUSample(timestamp: Date(),
                  gpuUsage: usage,
                  temperature: temperature,
                  thermalPressure: thermalPressure,
                  power: nil,
                  anePower: nil,
                  aneUsage: nil,
                  fanRPM: nil)
    }

    // MARK: - .temperature mode

    func testTemperatureNilIsNotBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .temperature, sample: sample(temperature: nil),
            aboveThresholdSince: nil, now: now)
        XCTAssertFalse(r.isBoiling)
        XCTAssertNil(r.newAboveThresholdSince)
    }

    func testTemperatureBelowThresholdIsNotBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .temperature, sample: sample(temperature: 84.9),
            aboveThresholdSince: nil, now: now)
        XCTAssertFalse(r.isBoiling)
    }

    func testTemperatureAtThresholdIsBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .temperature, sample: sample(temperature: 85),
            aboveThresholdSince: nil, now: now)
        XCTAssertTrue(r.isBoiling)
    }

    func testTemperatureAboveThresholdIsBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .temperature, sample: sample(temperature: 92),
            aboveThresholdSince: nil, now: now)
        XCTAssertTrue(r.isBoiling)
    }

    // MARK: - .thermalPressure mode

    func testThermalPressureNominalIsNotBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .thermalPressure, sample: sample(thermalPressure: "Nominal"),
            aboveThresholdSince: nil, now: now)
        XCTAssertFalse(r.isBoiling)
    }

    func testThermalPressureFairIsNotBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .thermalPressure, sample: sample(thermalPressure: "Fair"),
            aboveThresholdSince: nil, now: now)
        XCTAssertFalse(r.isBoiling)
    }

    func testThermalPressureSeriousIsBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .thermalPressure, sample: sample(thermalPressure: "Serious"),
            aboveThresholdSince: nil, now: now)
        XCTAssertTrue(r.isBoiling)
    }

    func testThermalPressureCriticalIsBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .thermalPressure, sample: sample(thermalPressure: "Critical"),
            aboveThresholdSince: nil, now: now)
        XCTAssertTrue(r.isBoiling)
    }

    // MARK: - .combined mode

    func testCombinedHighUsageStartsTimer() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .combined, sample: sample(usage: 0.95),
            aboveThresholdSince: nil, now: now)
        XCTAssertFalse(r.isBoiling)                      // Not yet 5s
        XCTAssertEqual(r.newAboveThresholdSince, now)    // Timer started
    }

    func testCombinedHighUsageBefore5sIsNotBoiling() {
        let started = now.addingTimeInterval(-4.9)
        let r = DockIconAnimator.computeBoiling(
            trigger: .combined, sample: sample(usage: 0.95),
            aboveThresholdSince: started, now: now)
        XCTAssertFalse(r.isBoiling)
    }

    func testCombinedHighUsageAfter5sIsBoiling() {
        let started = now.addingTimeInterval(-5.1)
        let r = DockIconAnimator.computeBoiling(
            trigger: .combined, sample: sample(usage: 0.95),
            aboveThresholdSince: started, now: now)
        XCTAssertTrue(r.isBoiling)
    }

    func testCombinedDropResetsTimer() {
        let started = now.addingTimeInterval(-3.0)
        let r = DockIconAnimator.computeBoiling(
            trigger: .combined, sample: sample(usage: 0.4),
            aboveThresholdSince: started, now: now)
        XCTAssertFalse(r.isBoiling)
        XCTAssertNil(r.newAboveThresholdSince)
    }

    func testCombinedThermalPressureSeriousImmediatelyBoils() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .combined,
            sample: sample(usage: 0.1, thermalPressure: "Serious"),
            aboveThresholdSince: nil, now: now)
        XCTAssertTrue(r.isBoiling)
    }
}
