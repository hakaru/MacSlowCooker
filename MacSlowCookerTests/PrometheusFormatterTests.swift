import XCTest
@testable import MacSlowCooker

final class PrometheusFormatterTests: XCTestCase {
    func testExpositionWithFullSample() {
        let sample = GPUSample(
            timestamp: Date(timeIntervalSince1970: 1778231262),
            gpuUsage: 0.42,
            temperature: 67.2,
            thermalPressure: .nominal,
            power: 8.4,
            anePower: 1.6,
            aneUsage: nil,
            fanRPM: [1850, 2100]
        )
        let body = PrometheusFormatter.exposition(sample: sample, helperConnected: true, version: "1.0.0")
        XCTAssertTrue(body.contains("# TYPE macslowcooker_gpu_usage_ratio gauge"))
        XCTAssertTrue(body.contains("\nmacslowcooker_gpu_usage_ratio 0.42\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_gpu_power_watts 8.4\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_ane_power_watts 1.6\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_temperature_celsius 67.2\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_thermal_pressure 0\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_fan_rpm{fan=\"0\"} 1850\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_fan_rpm{fan=\"1\"} 2100\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_helper_connected 1\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_build_info{version=\"1.0.0\"} 1\n"))
    }

    func testExpositionFanlessMacOmitsFanLines() {
        let sample = GPUSample(
            timestamp: Date(timeIntervalSince1970: 1778231262),
            gpuUsage: 0.10,
            temperature: nil,
            thermalPressure: nil,
            power: nil,
            anePower: nil,
            aneUsage: nil,
            fanRPM: nil
        )
        let body = PrometheusFormatter.exposition(sample: sample, helperConnected: true, version: "1.0.0")
        XCTAssertTrue(body.contains("\nmacslowcooker_gpu_usage_ratio 0.1\n"))
        XCTAssertFalse(body.contains("macslowcooker_fan_rpm"))
        XCTAssertFalse(body.contains("macslowcooker_temperature_celsius"))
        XCTAssertFalse(body.contains("macslowcooker_gpu_power_watts"))
        XCTAssertFalse(body.contains("macslowcooker_ane_power_watts"))
        XCTAssertFalse(body.contains("macslowcooker_thermal_pressure"))
    }

    func testExpositionHelperDownEmitsOnlyMetadata() {
        let body = PrometheusFormatter.exposition(sample: nil, helperConnected: false, version: "1.2.3")
        XCTAssertTrue(body.contains("\nmacslowcooker_helper_connected 0\n"))
        XCTAssertTrue(body.contains("macslowcooker_build_info{version=\"1.2.3\"} 1"))
        XCTAssertFalse(body.contains("macslowcooker_gpu_usage_ratio"))
    }
}
