import XCTest
@testable import MacSlowCooker

final class IOAcceleratorSelectionTests: XCTestCase {

    typealias Reading = IOAcceleratorSelection.Reading

    func testEmptyReadingsReturnsNil() {
        XCTAssertNil(IOAcceleratorSelection.choose(from: []))
    }

    func testAllNilUtilizationReturnsNil() {
        let r = [
            Reading(name: "AGXAccelerator", className: "AGXAccelerator", utilization: nil),
            Reading(name: "IntelAccelerator", className: "IntelAccelerator", utilization: nil),
        ]
        XCTAssertNil(IOAcceleratorSelection.choose(from: r))
    }

    func testSingleUsableServiceWins() {
        let r = [
            Reading(name: "AGXAccelerator", className: "AGXAccelerator", utilization: 42.0),
        ]
        let result = try? XCTUnwrap(IOAcceleratorSelection.choose(from: r))
        XCTAssertEqual(result?.chosen.utilization, 42.0)
        XCTAssertEqual(result?.sorted.count, 1)
    }

    /// First sorted-by-name service that has a usable percentage wins. Sorting
    /// makes the choice deterministic across reboots — without it, IOIterator
    /// order leaks into the GPU% reading.
    func testSortedByNameWhenMultipleUsable() {
        let r = [
            Reading(name: "ZetaAccelerator", className: "AGX", utilization: 70.0),
            Reading(name: "AGXAccelerator",  className: "AGX", utilization: 30.0),
            Reading(name: "MidAccelerator",  className: "AGX", utilization: 50.0),
        ]
        let result = try? XCTUnwrap(IOAcceleratorSelection.choose(from: r))
        XCTAssertEqual(result?.chosen.name, "AGXAccelerator")
        XCTAssertEqual(result?.chosen.utilization, 30.0)
        XCTAssertEqual(result?.sorted.map(\.name), ["AGXAccelerator", "MidAccelerator", "ZetaAccelerator"])
    }

    func testSkipsLeadingNilUtilization() {
        let r = [
            Reading(name: "AAA", className: "?", utilization: nil),
            Reading(name: "BBB", className: "?", utilization: 25.0),
            Reading(name: "CCC", className: "?", utilization: 40.0),
        ]
        let result = try? XCTUnwrap(IOAcceleratorSelection.choose(from: r))
        XCTAssertEqual(result?.chosen.name, "BBB")
        XCTAssertEqual(result?.chosen.utilization, 25.0)
    }

    // MARK: - normalize

    func testNormalizeMidRange() {
        XCTAssertEqual(IOAcceleratorSelection.normalize(percent: 42), 0.42, accuracy: 0.001)
    }

    func testNormalizeClampsAbove100() {
        XCTAssertEqual(IOAcceleratorSelection.normalize(percent: 150), 1.0)
    }

    func testNormalizeClampsBelow0() {
        XCTAssertEqual(IOAcceleratorSelection.normalize(percent: -10), 0.0)
    }
}
