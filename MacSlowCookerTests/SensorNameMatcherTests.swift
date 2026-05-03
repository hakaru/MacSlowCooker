import XCTest
@testable import MacSlowCooker

final class SensorNameMatcherTests: XCTestCase {

    // MARK: - Apple Silicon (M-series PMU sensors)

    func testMatchesPMUTdie() {
        XCTAssertTrue(SensorNameMatcher.shouldMatch(name: "PMU tdie0"))
        XCTAssertTrue(SensorNameMatcher.shouldMatch(name: "PMU tdie10"))
    }

    func testMatchesPMUTdev() {
        XCTAssertTrue(SensorNameMatcher.shouldMatch(name: "PMU tdev3"))
    }

    func testMatchesGPUMTRSensor() {
        XCTAssertTrue(SensorNameMatcher.shouldMatch(name: "GPU MTR Temp Sensor"))
    }

    // MARK: - Intel (AMD / Intel GPU sensors)

    func testMatchesGPUProximity() {
        XCTAssertTrue(SensorNameMatcher.shouldMatch(name: "GPU Proximity"))
    }

    func testMatchesGraphics() {
        XCTAssertTrue(SensorNameMatcher.shouldMatch(name: "Graphics Processor Die 0"))
    }

    // MARK: - Case insensitivity

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(SensorNameMatcher.shouldMatch(name: "GPU"))
        XCTAssertTrue(SensorNameMatcher.shouldMatch(name: "gpu"))
        XCTAssertTrue(SensorNameMatcher.shouldMatch(name: "Gpu"))
        XCTAssertTrue(SensorNameMatcher.shouldMatch(name: "DIE"))
    }

    // MARK: - Negative cases

    func testRejectsCPUSensor() {
        XCTAssertFalse(SensorNameMatcher.shouldMatch(name: "CPU Core 0"))
    }

    func testRejectsBatterySensor() {
        XCTAssertFalse(SensorNameMatcher.shouldMatch(name: "Battery Cell 1"))
    }

    func testRejectsAmbientSensor() {
        XCTAssertFalse(SensorNameMatcher.shouldMatch(name: "Ambient Temperature"))
    }

    func testRejectsEmptyString() {
        XCTAssertFalse(SensorNameMatcher.shouldMatch(name: ""))
    }
}
