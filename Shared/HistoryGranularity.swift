import Foundation

enum HistoryGranularity: Int, CaseIterable, Sendable {
    case fiveMin = 300
    case thirtyMin = 1800
    case twoHour = 7200
    case oneDay = 86400

    /// Seconds-aligned bucket size.
    var bucketSeconds: Int { rawValue }

    /// How long each table keeps rows before pruning.
    var retentionSeconds: Int {
        switch self {
        case .fiveMin:   return 24 * 3600          // 24h
        case .thirtyMin: return 7 * 24 * 3600      // 7d
        case .twoHour:   return 31 * 24 * 3600     // 31d
        case .oneDay:    return 400 * 24 * 3600    // ~13mo
        }
    }

    /// The coarser granularity that rolls up from this one (or nil if top).
    var nextCoarser: HistoryGranularity? {
        switch self {
        case .fiveMin:   return .thirtyMin
        case .thirtyMin: return .twoHour
        case .twoHour:   return .oneDay
        case .oneDay:    return nil
        }
    }

    /// SQLite table name.
    var tableName: String {
        switch self {
        case .fiveMin:   return "samples_5min"
        case .thirtyMin: return "samples_30min"
        case .twoHour:   return "samples_2hr"
        case .oneDay:    return "samples_1day"
        }
    }

    /// Filename-safe identifier used by the PNG exporter (`compute-daily.png` etc.).
    var id: String {
        switch self {
        case .fiveMin:   return "daily"
        case .thirtyMin: return "weekly"
        case .twoHour:   return "monthly"
        case .oneDay:    return "yearly"
        }
    }
}
