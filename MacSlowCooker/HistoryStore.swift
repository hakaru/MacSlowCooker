import Foundation
import SQLite3
import os

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Round-robin SQLite store for aggregate history. Not thread-safe;
/// access from one queue/actor.
final class HistoryStore {
    private var db: OpaquePointer?
    private let log = OSLog(subsystem: "com.macslowcooker.app", category: "HistoryStore")

    init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                 nil)
        guard rc == SQLITE_OK, let handle else {
            throw HistoryStoreError.open(rc)
        }
        self.db = handle
        try migrate()
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    enum HistoryStoreError: Error {
        case open(Int32)
        case prepare(Int32, String)
        case step(Int32)
    }

    // MARK: - Migration

    private func migrate() throws {
        for g in HistoryGranularity.allCases {
            let sql = """
            CREATE TABLE IF NOT EXISTS \(g.tableName) (
                ts INTEGER PRIMARY KEY,
                gpu_pct REAL, soc_temp_c REAL, power_w REAL, fan_rpm REAL
            );
            """
            try exec(sql)
        }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? ""
            sqlite3_free(err)
            throw HistoryStoreError.prepare(rc, msg)
        }
    }

    // MARK: - Insert / Query

    func insert(_ r: HistoryRecord, granularity: HistoryGranularity) throws {
        let sql = "INSERT OR REPLACE INTO \(granularity.tableName) (ts, gpu_pct, soc_temp_c, power_w, fan_rpm) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryStoreError.prepare(sqlite3_errcode(db), String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(r.ts))
        bindOptional(stmt, 2, r.gpuPct)
        bindOptional(stmt, 3, r.socTempC)
        bindOptional(stmt, 4, r.powerW)
        bindOptional(stmt, 5, r.fanRPM)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw HistoryStoreError.step(rc) }
    }

    func query(granularity: HistoryGranularity, sinceTs: Int, untilTs: Int) throws -> [HistoryRecord] {
        let sql = "SELECT ts, gpu_pct, soc_temp_c, power_w, fan_rpm FROM \(granularity.tableName) WHERE ts >= ? AND ts <= ? ORDER BY ts ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryStoreError.prepare(sqlite3_errcode(db), String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(sinceTs))
        sqlite3_bind_int64(stmt, 2, Int64(untilTs))
        var out: [HistoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(HistoryRecord(
                ts: Int(sqlite3_column_int64(stmt, 0)),
                gpuPct:   readOptional(stmt, 1),
                socTempC: readOptional(stmt, 2),
                powerW:   readOptional(stmt, 3),
                fanRPM:   readOptional(stmt, 4)
            ))
        }
        return out
    }

    // MARK: - Helpers

    private func bindOptional(_ stmt: OpaquePointer?, _ idx: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(stmt, idx, v) }
        else     { sqlite3_bind_null(stmt, idx) }
    }
    private func readOptional(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, idx)
    }
}
