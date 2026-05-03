import XCTest
@testable import MacSlowCooker

final class GPUSampleTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let sample = GPUSample(
            timestamp: Date(timeIntervalSince1970: 1000),
            gpuUsage: 0.68,
            temperature: 47.3,
            thermalPressure: "Nominal",
            power: 8.2,
            anePower: 0.5,
            aneUsage: 0.12,
            fanRPM: [1234, 1567]
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(GPUSample.self, from: data)

        XCTAssertEqual(decoded.gpuUsage, 0.68, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(decoded.temperature), 47.3, accuracy: 0.001)
        XCTAssertEqual(decoded.thermalPressure, "Nominal")
        XCTAssertEqual(try XCTUnwrap(decoded.power), 8.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(decoded.anePower), 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(decoded.aneUsage), 0.12, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(decoded.fanRPM), [1234, 1567])
    }

    func testNilFieldsEncodeDecodeRoundTrip() throws {
        let sample = GPUSample(
            timestamp: Date(),
            gpuUsage: 0.5,
            temperature: nil,
            thermalPressure: nil,
            power: nil,
            anePower: nil,
            aneUsage: nil,
            fanRPM: nil
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(GPUSample.self, from: data)

        XCTAssertNil(decoded.temperature)
        XCTAssertNil(decoded.thermalPressure)
        XCTAssertNil(decoded.power)
        XCTAssertNil(decoded.anePower)
        XCTAssertNil(decoded.aneUsage)
        XCTAssertNil(decoded.fanRPM)
    }
}
