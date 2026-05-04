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
        // Debug-only contract guard: `gpuUsage` is a ratio 0..1 (1 - idle_ratio
        // from powermetrics). If a future caller passes a percentage by
        // mistake, this assert catches it before the value gets multiplied to
        // 10000 and silently clipped at the chart's 100% ceiling.
        assert(sample.gpuUsage >= 0 && sample.gpuUsage <= 1.0,
               "gpuUsage must be a 0..1 ratio, got \(sample.gpuUsage)")

        let powerTotal: Double? = {
            switch (sample.power, sample.anePower) {
            case (nil, nil):           return nil
            case let (p?, nil):        return p
            case let (nil, a?):        return a
            case let (p?, a?):         return p + a
            }
        }()
        // GPUSample.gpuUsage is a 0..1 ratio; HistoryRecord.gpuPct is a
        // percentage 0..100 to match the visual scale used by the popup and
        // the MRTG yMaxHint of 100.
        return HistoryRecord(
            ts: bucketStart(sample.timestamp, granularity: granularity),
            gpuPct: sample.gpuUsage * 100,
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
