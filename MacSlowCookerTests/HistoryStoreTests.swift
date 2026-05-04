import XCTest
@testable import MacSlowCooker

final class HistoryStoreTests: XCTestCase {
    func testInsertAndQuerySingleRow5min() throws {
        let store = try HistoryStore(path: ":memory:")
        let r = HistoryRecord(ts: 1778231100, gpuPct: 42, socTempC: 60, powerW: 8, fanRPM: 1700)
        try store.insert(r, granularity: .fiveMin)
        let rows = try store.query(granularity: .fiveMin, sinceTs: 0, untilTs: Int.max)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], r)
    }
}
