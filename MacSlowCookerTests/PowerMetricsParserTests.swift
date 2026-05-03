import XCTest
@testable import MacSlowCooker

final class PowerMetricsParserTests: XCTestCase {

    func testParsePlistData() throws {
        let dict: [String: Any] = [
            "GPU": [
                "gpu_active_residency": 0.68,
                "gpu_power_mW": 8200.0
            ] as [String: Any],
            "ANE": [
                "ane_active_residency": 0.12
            ] as [String: Any],
            "thermal_pressure": "Nominal"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = PowerMetricsParser.parse(plistData: plistData, timestamp: Date(timeIntervalSince1970: 1000))

        XCTAssertNotNil(sample)
        XCTAssertEqual(try XCTUnwrap(sample?.gpuUsage), 0.68, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sample?.power), 8.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sample?.aneUsage), 0.12, accuracy: 0.001)
    }

    func testParseMissingGPUWithThermalReturnsSample() throws {
        let dict: [String: Any] = ["thermal_pressure": "Nominal"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = PowerMetricsParser.parse(plistData: plistData, timestamp: Date())

        XCTAssertNotNil(sample)
        XCTAssertNil(sample?.gpuUsage)
        XCTAssertEqual(sample?.thermalPressure, "Nominal")
    }

    func testParseEmptyDictReturnsNil() throws {
        let dict: [String: Any] = [:]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = PowerMetricsParser.parse(plistData: plistData, timestamp: Date())

        XCTAssertNil(sample)
    }

    func testParseNilOptionalFields() throws {
        let dict: [String: Any] = [
            "GPU": ["gpu_active_residency": 0.5] as [String: Any]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = PowerMetricsParser.parse(plistData: plistData, timestamp: Date())

        XCTAssertNotNil(sample)
        XCTAssertEqual(try XCTUnwrap(sample?.gpuUsage), 0.5, accuracy: 0.001)
        XCTAssertNil(sample?.temperature)
        XCTAssertNil(sample?.power)
        XCTAssertNil(sample?.aneUsage)
    }

    func testParseGpuBusyKey() throws {
        let dict: [String: Any] = [
            "gpu": ["gpu_busy": 42.5] as [String: Any]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = PowerMetricsParser.parse(plistData: plistData, timestamp: Date())

        XCTAssertNotNil(sample)
        XCTAssertEqual(try XCTUnwrap(sample?.gpuUsage), 0.425, accuracy: 0.001)
    }

    func testParseBusyNsKey() throws {
        let dict: [String: Any] = [
            "gpu": [
                "busy_ns": 500_000_000.0,
                "elapsed_ns": 1_000_000_000.0
            ] as [String: Any]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = PowerMetricsParser.parse(plistData: plistData, timestamp: Date())

        XCTAssertNotNil(sample)
        XCTAssertEqual(try XCTUnwrap(sample?.gpuUsage), 0.5, accuracy: 0.001)
    }
}
