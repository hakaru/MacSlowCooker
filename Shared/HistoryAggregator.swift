import Foundation

enum HistoryAggregator {
    /// Floor `ts` to the start of its bucket for `granularity`.
    static func bucketStart(_ ts: Date, granularity: HistoryGranularity) -> Int {
        let s = Int(ts.timeIntervalSince1970)
        let g = granularity.bucketSeconds
        return s - (s % g)
    }
}

extension HistoryAggregator {
    static func record(from sample: GPUSample, granularity: HistoryGranularity) -> HistoryRecord {
        let powerTotal: Double? = {
            switch (sample.power, sample.anePower) {
            case (nil, nil):           return nil
            case let (p?, nil):        return p
            case let (nil, a?):        return a
            case let (p?, a?):         return p + a
            }
        }()
        return HistoryRecord(
            ts: bucketStart(sample.timestamp, granularity: granularity),
            gpuPct: sample.gpuUsage,
            socTempC: sample.temperature,
            powerW: powerTotal,
            fanRPM: sample.fanRPM?.max()
        )
    }
}

extension HistoryAggregator {
    static func average(_ records: [HistoryRecord], at bucketTs: Int) -> HistoryRecord? {
        guard !records.isEmpty else { return nil }
        func avg(_ pick: (HistoryRecord) -> Double?) -> Double? {
            let vals = records.compactMap(pick)
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Double(vals.count)
        }
        return HistoryRecord(
            ts: bucketTs,
            gpuPct:  avg { $0.gpuPct },
            socTempC: avg { $0.socTempC },
            powerW:  avg { $0.powerW },
            fanRPM:  avg { $0.fanRPM }
        )
    }
}
