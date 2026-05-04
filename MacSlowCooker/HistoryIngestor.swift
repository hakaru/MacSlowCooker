import Foundation
import os

/// Buffers raw GPUSamples into the active 5-min bucket; on rollover, flushes
/// the average to HistoryStore and triggers the rollup chain.
@MainActor
final class HistoryIngestor {
    private let store: HistoryStore
    private let log = OSLog(subsystem: "com.macslowcooker.app", category: "HistoryIngestor")

    private var currentBucketTs: Int?
    private var buffered: [HistoryRecord] = []

    init(store: HistoryStore) {
        self.store = store
    }

    func ingest(_ sample: GPUSample) {
        let r = HistoryAggregator.record(from: sample, granularity: .fiveMin)
        if let cur = currentBucketTs, cur != r.ts {
            flush(bucketTs: cur)
        }
        currentBucketTs = r.ts
        buffered.append(r)
    }

    /// Force-flush the current bucket (e.g. on app termination).
    func flushPending() {
        if let cur = currentBucketTs {
            flush(bucketTs: cur)
            currentBucketTs = nil
        }
    }

    private func flush(bucketTs: Int) {
        guard let avg = HistoryAggregator.average(buffered, at: bucketTs) else {
            buffered.removeAll(); return
        }
        do {
            try store.insert(avg, granularity: .fiveMin)
            try cascadeRollups(after: bucketTs)
            try pruneAll(nowTs: bucketTs)
        } catch {
            os_log("history flush failed: %{public}@", log: log, type: .error, String(describing: error))
        }
        buffered.removeAll()
    }

    /// After a finer bucket lands, if its parent coarser bucket boundary is now
    /// past, trigger the rollup. Cascades up the granularity chain.
    ///
    /// Known limitation: only catches up one bucket per level per call. If the app
    /// is offline across multiple coarser-bucket boundaries (e.g. Mac slept for
    /// hours), only the boundary containing `finerBucketTs` is rolled up. v1
    /// accepts the gap; a future revision could query for stale dst buckets.
    private func cascadeRollups(after finerBucketTs: Int) throws {
        var src = HistoryGranularity.fiveMin
        var srcTs = finerBucketTs
        while let dst = src.nextCoarser {
            // Has the dst bucket containing srcTs *just* completed? It's complete
            // when the *next* src bucket (srcTs + src.seconds) sits in a new dst.
            let dstStart  = srcTs - (srcTs % dst.bucketSeconds)
            let nextSrc   = srcTs + src.bucketSeconds
            let nextDst   = nextSrc - (nextSrc % dst.bucketSeconds)
            guard nextDst != dstStart else { break }
            try store.rollup(from: src, into: dst, bucketTs: dstStart)
            src = dst
            srcTs = dstStart
        }
    }

    private func pruneAll(nowTs: Int) throws {
        for g in HistoryGranularity.allCases {
            try store.prune(granularity: g, nowTs: nowTs)
        }
    }
}
