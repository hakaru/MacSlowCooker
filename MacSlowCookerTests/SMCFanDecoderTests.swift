import XCTest
@testable import MacSlowCooker

final class SMCFanDecoderTests: XCTestCase {

    // MARK: - fpe2 (16-bit big-endian fixed point, 14-int + 2-frac → raw / 4.0)

    func testFpe2ZeroRPM() {
        XCTAssertEqual(SMCFanDecoder.decode(bytes: [0x00, 0x00], dataType: "fpe2"), 0.0)
    }

    func testFpe2IntegerRPM() {
        // 1500 RPM × 4 = 6000 = 0x1770 → bytes [0x17, 0x70]
        XCTAssertEqual(SMCFanDecoder.decode(bytes: [0x17, 0x70], dataType: "fpe2"), 1500.0)
    }

    func testFpe2FractionalRPM() {
        // 1234.25 × 4 = 4937 = 0x1349 → bytes [0x13, 0x49]
        let result = SMCFanDecoder.decode(bytes: [0x13, 0x49], dataType: "fpe2")
        XCTAssertEqual(try XCTUnwrap(result), 1234.25, accuracy: 0.01)
    }

    func testFpe2MaxRPM() {
        // 0xFFFF / 4 = 16383.75 (max representable)
        let result = SMCFanDecoder.decode(bytes: [0xFF, 0xFF], dataType: "fpe2")
        XCTAssertEqual(try XCTUnwrap(result), 16383.75, accuracy: 0.01)
    }

    func testFpe2ShortBufferReturnsNil() {
        XCTAssertNil(SMCFanDecoder.decode(bytes: [0x17], dataType: "fpe2"))
        XCTAssertNil(SMCFanDecoder.decode(bytes: [], dataType: "fpe2"))
    }

    // MARK: - flt (32-bit little-endian IEEE 754 float)

    func testFltZero() {
        XCTAssertEqual(SMCFanDecoder.decode(bytes: [0, 0, 0, 0], dataType: "flt "), 0.0)
    }

    func testFltOne() {
        // 1.0 in IEEE 754 = 0x3F800000 — little-endian on disk: 00 00 80 3F
        XCTAssertEqual(SMCFanDecoder.decode(bytes: [0x00, 0x00, 0x80, 0x3F], dataType: "flt "), 1.0)
    }

    func testFlt1500RPM() {
        // 1500.0 in IEEE 754 = 0x44BB8000 — little-endian: 00 80 BB 44
        let result = SMCFanDecoder.decode(bytes: [0x00, 0x80, 0xBB, 0x44], dataType: "flt ")
        XCTAssertEqual(try XCTUnwrap(result), 1500.0, accuracy: 0.001)
    }

    func testFltShortBufferReturnsNil() {
        XCTAssertNil(SMCFanDecoder.decode(bytes: [0, 0, 0], dataType: "flt "))
        XCTAssertNil(SMCFanDecoder.decode(bytes: [], dataType: "flt "))
    }

    // MARK: - Unknown type

    func testUnknownDataTypeReturnsNil() {
        XCTAssertNil(SMCFanDecoder.decode(bytes: [0xFF, 0xFF], dataType: "ui16"))
        XCTAssertNil(SMCFanDecoder.decode(bytes: [0xFF, 0xFF, 0xFF, 0xFF], dataType: "ui32"))
        XCTAssertNil(SMCFanDecoder.decode(bytes: [0xFF, 0xFF], dataType: ""))
    }
}
