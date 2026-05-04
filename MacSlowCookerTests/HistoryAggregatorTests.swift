// MacSlowCookerTests/HistoryAggregatorTests.swift
import XCTest
@testable import MacSlowCooker

final class HistoryAggregatorTests: XCTestCase {
    func testBucketStartAlignsToGranularity() {
        // 2026-05-04 10:07:42 UTC = 1778231262
        let ts = Date(timeIntervalSince1970: 1778231262)
        XCTAssertEqual(HistoryAggregator.bucketStart(ts, granularity: .fiveMin),   1778231100) // 10:05:00
        XCTAssertEqual(HistoryAggregator.bucketStart(ts, granularity: .thirtyMin), 1778230800) // 10:00:00
        XCTAssertEqual(HistoryAggregator.bucketStart(ts, granularity: .twoHour),   1778227200) // 08:00:00
        XCTAssertEqual(HistoryAggregator.bucketStart(ts, granularity: .oneDay),    1778198400) // 00:00:00
    }

    func testRecordFromSampleSumsPowerAndTakesMaxFan() {
        // GPUSample.gpuUsage is a 0..1 ratio; HistoryRecord.gpuPct is a 0..100 percentage.
        let sample = GPUSample(
            timestamp: Date(timeIntervalSince1970: 1778231262),
            gpuUsage: 0.425,
            temperature: 67.2,
            thermalPressure: nil,
            power: 8.4,
            anePower: 1.6,
            aneUsage: nil,
            fanRPM: [1850, 2100, 1700]
        )
        let r = HistoryAggregator.record(from: sample, granularity: .fiveMin)
        XCTAssertEqual(r.ts, 1778231100)
        XCTAssertEqual(r.gpuPct ?? 0, 42.5, accuracy: 0.001)
        XCTAssertEqual(r.socTempC, 67.2)
        XCTAssertEqual(r.powerW ?? 0, 10.0, accuracy: 0.001)
        XCTAssertEqual(r.fanRPM ?? 0, 2100)
    }

    func testRecordFromSampleHandlesAllNils() {
        let sample = GPUSample(
            timestamp: Date(timeIntervalSince1970: 1778231262),
            gpuUsage: 0,
            temperature: nil,
            thermalPressure: nil,
            power: nil,
            anePower: nil,
            aneUsage: nil,
            fanRPM: nil
        )
        let r = HistoryAggregator.record(from: sample, granularity: .fiveMin)
        XCTAssertNil(r.socTempC)
        XCTAssertNil(r.powerW)
        XCTAssertNil(r.fanRPM)
    }

    func testAverageIgnoresNilsPerField() {
        let bucket = 1778231100
        let recs: [HistoryRecord] = [
            HistoryRecord(ts: bucket, gpuPct: 30, socTempC: 60,  powerW: 5,    fanRPM: 1500),
            HistoryRecord(ts: bucket, gpuPct: 50, socTempC: nil, powerW: 10,   fanRPM: nil),
            HistoryRecord(ts: bucket, gpuPct: 40, socTempC: 70,  powerW: nil,  fanRPM: 1800),
        ]
        let avg = HistoryAggregator.average(recs, at: bucket)
        XCTAssertNotNil(avg)
        XCTAssertEqual(avg?.ts, bucket)
        XCTAssertEqual(avg?.gpuPct ?? 0, 40, accuracy: 0.001)        // (30+50+40)/3
        XCTAssertEqual(avg?.socTempC ?? 0, 65, accuracy: 0.001)      // (60+70)/2
        XCTAssertEqual(avg?.powerW ?? 0, 7.5, accuracy: 0.001)       // (5+10)/2
        XCTAssertEqual(avg?.fanRPM ?? 0, 1650, accuracy: 0.001)      // (1500+1800)/2
    }

    func testAverageReturnsNilForEmptyInput() {
        XCTAssertNil(HistoryAggregator.average([], at: 0))
    }

    func testAverageAllNilFieldStaysNil() {
        let bucket = 1778231100
        let recs: [HistoryRecord] = [
            HistoryRecord(ts: bucket, gpuPct: 30, socTempC: nil, powerW: 5, fanRPM: nil),
            HistoryRecord(ts: bucket, gpuPct: 40, socTempC: nil, powerW: 7, fanRPM: nil),
        ]
        let avg = HistoryAggregator.average(recs, at: bucket)
        XCTAssertNil(avg?.socTempC)
        XCTAssertNil(avg?.fanRPM)
    }
}
