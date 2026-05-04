import XCTest
@testable import MacSlowCooker

@MainActor
final class HistoryIngestorTests: XCTestCase {

    func testIngestFlushesOnBucketRollover() throws {
        let store = try HistoryStore(path: ":memory:")
        let ingestor = HistoryIngestor(store: store)
        // bucket A: 1778231100..1778231399 inclusive
        let a1 = sample(ts: 1778231100, gpu: 10)
        let a2 = sample(ts: 1778231300, gpu: 30)
        ingestor.ingest(a1)
        ingestor.ingest(a2)
        // before rollover, nothing in store
        XCTAssertEqual(try store.query(granularity: .fiveMin, sinceTs: 0, untilTs: .max).count, 0)
        // bucket B: 1778231400..
        ingestor.ingest(sample(ts: 1778231400, gpu: 50))
        // bucket A flushed
        let rows = try store.query(granularity: .fiveMin, sinceTs: 0, untilTs: .max)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].ts, 1778231100)
        XCTAssertEqual(rows[0].gpuPct ?? 0, 20, accuracy: 0.001)
    }

    func testIngestCascadesRollupAfterSixthFiveMinBucket() throws {
        let store = try HistoryStore(path: ":memory:")
        let ingestor = HistoryIngestor(store: store)
        // Insert 7 buckets of 5min data covering one full 30-min bucket [start, start+30min).
        let start = 1778230800  // aligned to 30min
        for i in 0...6 {
            let s = sample(ts: TimeInterval(start + i*300), gpu: Double(i*10))
            ingestor.ingest(s)
        }
        // After ingesting bucket #6 (which lands in the *next* 30-min window),
        // the previous 30-min should be rolled up.
        let thirty = try store.query(granularity: .thirtyMin, sinceTs: 0, untilTs: .max)
        XCTAssertEqual(thirty.count, 1)
        XCTAssertEqual(thirty[0].ts, start)
        // gpu values 0,10,20,30,40,50 in 5min table → avg 25
        XCTAssertEqual(thirty[0].gpuPct ?? 0, 25, accuracy: 0.001)
    }

    private func sample(ts: TimeInterval, gpu: Double) -> GPUSample {
        GPUSample(timestamp: Date(timeIntervalSince1970: ts),
                  gpuUsage: gpu, temperature: 50, thermalPressure: nil,
                  power: 5, anePower: nil, aneUsage: nil, fanRPM: [1500])
    }
}
