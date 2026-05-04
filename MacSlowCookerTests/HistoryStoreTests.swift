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

    func testPruneDropsRowsOlderThanRetention() throws {
        let store = try HistoryStore(path: ":memory:")
        let now = 1778231100
        // 25h ago — outside 24h retention for 5min
        try store.insert(HistoryRecord(ts: now - 25*3600, gpuPct: 1, socTempC: nil, powerW: nil, fanRPM: nil), granularity: .fiveMin)
        // 10min ago — inside
        try store.insert(HistoryRecord(ts: now - 600,    gpuPct: 2, socTempC: nil, powerW: nil, fanRPM: nil), granularity: .fiveMin)
        try store.prune(granularity: .fiveMin, nowTs: now)
        let rows = try store.query(granularity: .fiveMin, sinceTs: 0, untilTs: Int.max)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].gpuPct, 2)
    }

    func testRollupAveragesSourceRowsIntoCoarserBucket() throws {
        let store = try HistoryStore(path: ":memory:")
        // 30-min bucket starts at 1778230800. Insert six 5-min rows covering
        // the bucket [1778230800, 1778232600).
        for i in 0..<6 {
            let r = HistoryRecord(ts: 1778230800 + i*300,
                                  gpuPct: Double(10 * (i+1)),  // 10..60
                                  socTempC: 50,
                                  powerW: 5,
                                  fanRPM: 1500)
            try store.insert(r, granularity: .fiveMin)
        }
        try store.rollup(from: .fiveMin, into: .thirtyMin, bucketTs: 1778230800)
        let rows = try store.query(granularity: .thirtyMin, sinceTs: 0, untilTs: Int.max)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].ts, 1778230800)
        XCTAssertEqual(rows[0].gpuPct ?? 0, 35, accuracy: 0.001)  // (10+20+...+60)/6
        XCTAssertEqual(rows[0].socTempC, 50)
    }
}
