import Foundation

/// One bucket-aligned aggregate row. Each metric is independently optional
/// because Tahoe drops GPU temp and fanless Macs have no fan RPM.
struct HistoryRecord: Equatable, Sendable {
    /// Bucket-start unix epoch seconds (aligned to granularity).
    let ts: Int
    let gpuPct: Double?
    let socTempC: Double?
    let powerW: Double?
    let fanRPM: Double?

    static let empty = HistoryRecord(ts: 0, gpuPct: nil, socTempC: nil, powerW: nil, fanRPM: nil)
}
