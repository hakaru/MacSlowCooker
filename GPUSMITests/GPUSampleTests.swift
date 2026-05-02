import XCTest
@testable import GPUSMI

final class GPUSampleTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let sample = GPUSample(
            timestamp: Date(timeIntervalSince1970: 1000),
            gpuUsage: 0.68,
            temperature: 47.3,
            power: 8.2,
            aneUsage: 0.12
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(GPUSample.self, from: data)

        XCTAssertEqual(decoded.gpuUsage, 0.68, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(decoded.temperature), 47.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(decoded.power), 8.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(decoded.aneUsage), 0.12, accuracy: 0.001)
    }

    func testNilFieldsEncodeDecodeRoundTrip() throws {
        let sample = GPUSample(
            timestamp: Date(),
            gpuUsage: 0.5,
            temperature: nil,
            power: nil,
            aneUsage: nil
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(GPUSample.self, from: data)

        XCTAssertNil(decoded.temperature)
        XCTAssertNil(decoded.power)
        XCTAssertNil(decoded.aneUsage)
    }
}
