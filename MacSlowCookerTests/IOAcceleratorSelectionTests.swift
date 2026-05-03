import XCTest
@testable import MacSlowCooker

final class IOAcceleratorSelectionTests: XCTestCase {

    typealias Reading = IOAcceleratorSelection.Reading

    func testEmptyReadingsReturnsNil() {
        XCTAssertNil(IOAcceleratorSelection.aggregate(from: []))
    }

    func testAllNilUtilizationReturnsNil() {
        let r = [
            Reading(name: "AGXAccelerator", className: "AGXAccelerator", utilization: nil),
            Reading(name: "IntelAccelerator", className: "IntelAccelerator", utilization: nil),
        ]
        XCTAssertNil(IOAcceleratorSelection.aggregate(from: r))
    }

    func testSingleUsableServiceWins() {
        let r = [
            Reading(name: "AGXAccelerator", className: "AGXAccelerator", utilization: 42.0),
        ]
        let result = try? XCTUnwrap(IOAcceleratorSelection.aggregate(from: r))
        XCTAssertEqual(result?.utilization, 42.0)
        XCTAssertEqual(result?.contributingCount, 1)
        XCTAssertEqual(result?.sortedReadings.count, 1)
    }

    /// Multi-GPU aggregation: take the max so the dock icon reflects the
    /// busiest GPU rather than averaging away a real bottleneck.
    func testMaxAcrossMultipleUsable() {
        let r = [
            Reading(name: "ZetaAccelerator", className: "AGX", utilization: 70.0),
            Reading(name: "AGXAccelerator",  className: "AGX", utilization: 30.0),
            Reading(name: "MidAccelerator",  className: "AGX", utilization: 50.0),
        ]
        let result = try? XCTUnwrap(IOAcceleratorSelection.aggregate(from: r))
        XCTAssertEqual(result?.utilization, 70.0)
        XCTAssertEqual(result?.contributingCount, 3)
    }

    /// Sorted readings are exposed for first-read logging; order is by name
    /// regardless of which service contributed the max.
    func testSortedReadingsRegardlessOfMaxLocation() {
        let r = [
            Reading(name: "ZetaAccelerator", className: "AGX", utilization: 70.0),
            Reading(name: "AGXAccelerator",  className: "AGX", utilization: 30.0),
        ]
        let result = try? XCTUnwrap(IOAcceleratorSelection.aggregate(from: r))
        XCTAssertEqual(result?.sortedReadings.map(\.name), ["AGXAccelerator", "ZetaAccelerator"])
    }

    /// Mixed nil + usable: nil readings count as zero contributors, max
    /// taken across only the usable ones.
    func testNilReadingsExcludedFromMax() {
        let r = [
            Reading(name: "AAA", className: "?", utilization: nil),
            Reading(name: "BBB", className: "?", utilization: 25.0),
            Reading(name: "CCC", className: "?", utilization: 40.0),
        ]
        let result = try? XCTUnwrap(IOAcceleratorSelection.aggregate(from: r))
        XCTAssertEqual(result?.utilization, 40.0)
        XCTAssertEqual(result?.contributingCount, 2)
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
