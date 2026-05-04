# History & MRTG-style Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist GPU/temp/power/fan samples into a round-robin SQLite store and surface them in a separate MRTG-style window with Daily / Weekly / Monthly / Yearly panels.

**Architecture:** App-side ingest. The unprivileged `MacSlowCooker.app` already receives every `GPUSample` via XPC at 2 Hz; we tap that callback and write into 4 round-robin tables (5-min / 30-min / 2-hour / 1-day) under `~/Library/Application Support/MacSlowCooker/history.sqlite`. Aggregation is pure (in `Shared/HistoryAggregator.swift`) and unit-tested. The viewer is a separate `NSWindow` driven by a SwiftUI `Canvas`-based renderer with per-metric tabs (GPU / Temp / Power / Fan), each tab showing four stacked time-range graphs.

**Tech Stack:**
- Swift 6, SwiftUI (existing pattern), `NSWindowController` (existing pattern)
- `import SQLite3` (built into macOS — no new dependencies)
- `Canvas` (SwiftUI) for graph rendering
- XCTest, with `:memory:` SQLite for store tests

**Out of scope (stage 2):** SNMP agent, Prometheus exporter, static PNG export, network ingestion. This plan only covers local persistence + viewer.

---

## File Structure

**Create (new):**
- `Shared/HistoryRecord.swift` — pure value type for one bucket-aligned aggregate row
- `Shared/HistoryGranularity.swift` — enum for the 4 RRA resolutions
- `Shared/HistoryAggregator.swift` — pure: GPUSample → HistoryRecord, bucket alignment, averaging
- `MacSlowCooker/HistoryStore.swift` — SQLite wrapper (open / migrate / insert / query / prune / rollup)
- `MacSlowCooker/HistoryIngestor.swift` — in-memory 5-min bucket buffer; flushes to HistoryStore on rollover
- `MacSlowCooker/MRTGGraphView.swift` — SwiftUI `Canvas` view: filled-area graph + grid + axis labels for one (granularity × metric) slice
- `MacSlowCooker/HistoryView.swift` — SwiftUI tabbed root view (4 metric tabs × 4 stacked graphs each)
- `MacSlowCooker/HistoryWindowController.swift` — `NSWindowController` hosting `HistoryView`
- `MacSlowCookerTests/HistoryAggregatorTests.swift`
- `MacSlowCookerTests/HistoryStoreTests.swift`
- `MacSlowCookerTests/HistoryIngestorTests.swift`

**Modify:**
- `MacSlowCooker/AppDelegate.swift` — own a `HistoryIngestor`; wire `xpcClient.onSample` → ingestor; add "History…" menu item that opens `HistoryWindowController`
- `project.yml` — add new files (xcodegen picks them up by glob, but verify) and link `libsqlite3.tbd` to the app target
- `CLAUDE.md` — short note on the new history subsystem under "Architecture"

**Conventions followed:**
- Pure logic in `Shared/`, IO-bound code in app target (mirrors the existing SMC / IOAccelerator / Parser split).
- `@Observable` and `@MainActor` discipline for app-target types that touch UI.
- New Swift files require `xcodegen generate` (per CLAUDE.md "SourceKit false positives" section).

---

### Task 1: HistoryRecord + HistoryGranularity (pure types)

**Files:**
- Create: `Shared/HistoryRecord.swift`
- Create: `Shared/HistoryGranularity.swift`
- Test: `MacSlowCookerTests/HistoryAggregatorTests.swift` (created here, populated in Task 2)

- [ ] **Step 1: Write `Shared/HistoryGranularity.swift`**

```swift
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
}
```

- [ ] **Step 2: Write `Shared/HistoryRecord.swift`**

```swift
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
```

- [ ] **Step 3: Create empty test file**

```swift
// MacSlowCookerTests/HistoryAggregatorTests.swift
import XCTest
@testable import MacSlowCooker

final class HistoryAggregatorTests: XCTestCase {
    // populated in Task 2
}
```

- [ ] **Step 4: Run xcodegen + build**

Run: `xcodegen generate && xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet`
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Shared/HistoryRecord.swift Shared/HistoryGranularity.swift MacSlowCookerTests/HistoryAggregatorTests.swift project.yml MacSlowCooker.xcodeproj
git commit -m "feat(history): add HistoryRecord and HistoryGranularity value types"
```

---

### Task 2: HistoryAggregator (pure logic)

**Files:**
- Create: `Shared/HistoryAggregator.swift`
- Test: `MacSlowCookerTests/HistoryAggregatorTests.swift`

- [ ] **Step 1: Write failing test for bucket alignment**

Append to `HistoryAggregatorTests.swift`:

```swift
func testBucketStartAlignsToGranularity() {
    // 2026-05-04 10:07:42 UTC = 1778231262
    let ts = Date(timeIntervalSince1970: 1778231262)
    XCTAssertEqual(HistoryAggregator.bucketStart(ts, granularity: .fiveMin),   1778231100) // 10:05:00
    XCTAssertEqual(HistoryAggregator.bucketStart(ts, granularity: .thirtyMin), 1778230800) // 10:00:00
    XCTAssertEqual(HistoryAggregator.bucketStart(ts, granularity: .twoHour),   1778227200) // 08:00:00
    XCTAssertEqual(HistoryAggregator.bucketStart(ts, granularity: .oneDay),    1778198400) // 00:00:00
}
```

- [ ] **Step 2: Run test, verify failure**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/HistoryAggregatorTests/testBucketStartAlignsToGranularity`
Expected: FAIL (`HistoryAggregator` undefined).

- [ ] **Step 3: Write minimal `Shared/HistoryAggregator.swift`**

```swift
import Foundation

enum HistoryAggregator {
    /// Floor `ts` to the start of its bucket for `granularity`.
    static func bucketStart(_ ts: Date, granularity: HistoryGranularity) -> Int {
        let s = Int(ts.timeIntervalSince1970)
        let g = granularity.bucketSeconds
        return s - (s % g)
    }
}
```

- [ ] **Step 4: Run test, verify pass**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Add failing test for sample → record conversion**

```swift
func testRecordFromSampleSumsPowerAndTakesMaxFan() {
    let sample = GPUSample(
        timestamp: Date(timeIntervalSince1970: 1778231262),
        gpuUsage: 42.5,
        temperature: 67.2,
        thermalPressure: nil,
        power: 8.4,
        anePower: 1.6,
        aneUsage: nil,
        fanRPM: [1850, 2100, 1700]
    )
    let r = HistoryAggregator.record(from: sample, granularity: .fiveMin)
    XCTAssertEqual(r.ts, 1778231100)
    XCTAssertEqual(r.gpuPct, 42.5)
    XCTAssertEqual(r.socTempC, 67.2)
    XCTAssertEqual(r.powerW, 10.0, accuracy: 0.001)
    XCTAssertEqual(r.fanRPM, 2100)
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
```

- [ ] **Step 6: Implement `record(from:granularity:)`**

Append to `HistoryAggregator.swift`:

```swift
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
```

- [ ] **Step 7: Run tests, verify pass**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/HistoryAggregatorTests`
Expected: PASS.

- [ ] **Step 8: Add failing test for averaging**

```swift
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
```

- [ ] **Step 9: Implement `average(_:at:)`**

Append:

```swift
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
```

- [ ] **Step 10: Run all aggregator tests**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/HistoryAggregatorTests`
Expected: all 5 pass.

- [ ] **Step 11: Commit**

```bash
git add Shared/HistoryAggregator.swift MacSlowCookerTests/HistoryAggregatorTests.swift
git commit -m "feat(history): pure HistoryAggregator (bucket alignment, averaging, sample mapping)"
```

---

### Task 3: HistoryStore — open, migrate, insert into 5-min table

**Files:**
- Create: `MacSlowCooker/HistoryStore.swift`
- Test: `MacSlowCookerTests/HistoryStoreTests.swift`
- Modify: `project.yml` (link `libsqlite3.tbd`)

- [ ] **Step 1: Add libsqlite3 to app target in `project.yml`**

Locate the `MacSlowCooker:` target block and add to `dependencies:` (or create the list if absent):

```yaml
    dependencies:
      - sdk: libsqlite3.tbd
```

Then run `xcodegen generate`.

- [ ] **Step 2: Write failing test — open in-memory DB and insert one row**

`MacSlowCookerTests/HistoryStoreTests.swift`:

```swift
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
```

- [ ] **Step 3: Run test, verify failure**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/HistoryStoreTests/testInsertAndQuerySingleRow5min`
Expected: FAIL (`HistoryStore` undefined).

- [ ] **Step 4: Implement minimal `HistoryStore`**

`MacSlowCooker/HistoryStore.swift`:

```swift
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
```

- [ ] **Step 5: Run test, verify pass**

Same command as Step 3. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add MacSlowCooker/HistoryStore.swift MacSlowCookerTests/HistoryStoreTests.swift project.yml MacSlowCooker.xcodeproj
git commit -m "feat(history): SQLite-backed HistoryStore with insert/query for 5min table"
```

---

### Task 4: HistoryStore — pruning + rollup

**Files:**
- Modify: `MacSlowCooker/HistoryStore.swift`
- Modify: `MacSlowCookerTests/HistoryStoreTests.swift`

- [ ] **Step 1: Add failing pruning test**

```swift
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
```

- [ ] **Step 2: Run test, verify failure**

Expected: FAIL (`prune` undefined).

- [ ] **Step 3: Implement `prune`**

In `HistoryStore`:

```swift
func prune(granularity: HistoryGranularity, nowTs: Int) throws {
    let cutoff = nowTs - granularity.retentionSeconds
    let sql = "DELETE FROM \(granularity.tableName) WHERE ts < \(cutoff);"
    try exec(sql)
}
```

- [ ] **Step 4: Run test, verify pass**

- [ ] **Step 5: Add failing rollup test**

```swift
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
```

- [ ] **Step 6: Run test, verify failure**

- [ ] **Step 7: Implement `rollup(from:into:bucketTs:)`**

```swift
func rollup(from src: HistoryGranularity, into dst: HistoryGranularity, bucketTs: Int) throws {
    precondition(dst.bucketSeconds > src.bucketSeconds, "dst must be coarser than src")
    let end = bucketTs + dst.bucketSeconds  // exclusive
    let rows = try query(granularity: src, sinceTs: bucketTs, untilTs: end - 1)
    guard let avg = HistoryAggregator.average(rows, at: bucketTs) else { return }
    try insert(avg, granularity: dst)
}
```

- [ ] **Step 8: Run all HistoryStore tests, verify pass**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/HistoryStoreTests`
Expected: 3/3 pass.

- [ ] **Step 9: Commit**

```bash
git add MacSlowCooker/HistoryStore.swift MacSlowCookerTests/HistoryStoreTests.swift
git commit -m "feat(history): retention pruning + rollup from finer to coarser granularity"
```

---

### Task 5: HistoryIngestor — in-memory bucket buffer

**Files:**
- Create: `MacSlowCooker/HistoryIngestor.swift`
- Test: `MacSlowCookerTests/HistoryIngestorTests.swift`

This component owns a 5-min in-memory buffer and flushes to `HistoryStore` on bucket rollover. It also drives the rollup chain (5→30→2hr→1day) when each coarser bucket completes, and prunes once per flush.

- [ ] **Step 1: Write failing test — flush on bucket rollover**

```swift
import XCTest
@testable import MacSlowCooker

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

    private func sample(ts: TimeInterval, gpu: Double) -> GPUSample {
        GPUSample(timestamp: Date(timeIntervalSince1970: ts),
                  gpuUsage: gpu, temperature: 50, thermalPressure: nil,
                  power: 5, anePower: nil, aneUsage: nil, fanRPM: [1500])
    }
}
```

- [ ] **Step 2: Run test, verify failure**

Expected: FAIL (`HistoryIngestor` undefined).

- [ ] **Step 3: Implement `HistoryIngestor`**

`MacSlowCooker/HistoryIngestor.swift`:

```swift
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
```

- [ ] **Step 4: Run test, verify pass**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Add failing test — rollup cascade fires on 30-min boundary**

```swift
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
```

- [ ] **Step 6: Run test, verify pass**

Expected: PASS (logic already in place).

- [ ] **Step 7: Run all ingestor tests**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/HistoryIngestorTests`
Expected: 2/2 pass.

- [ ] **Step 8: Commit**

```bash
git add MacSlowCooker/HistoryIngestor.swift MacSlowCookerTests/HistoryIngestorTests.swift
git commit -m "feat(history): HistoryIngestor with 5min buffering and cascading rollup"
```

---

### Task 6: Wire ingestor into AppDelegate

**Files:**
- Modify: `MacSlowCooker/AppDelegate.swift`

- [ ] **Step 1: Add `historyStore` and `historyIngestor` properties**

In `AppDelegate.swift`, near other stored properties:

```swift
private let historyStore: HistoryStore? = {
    do {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacSlowCooker", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try HistoryStore(path: dir.appendingPathComponent("history.sqlite").path)
    } catch {
        os_log("HistoryStore init failed: %{public}@", log: log, type: .error, String(describing: error))
        return nil
    }
}()

private lazy var historyIngestor: HistoryIngestor? = historyStore.map { HistoryIngestor(store: $0) }
```

- [ ] **Step 2: Tap the existing onSample callback**

In `connectXPC()`, modify the `xpcClient.onSample` block (currently at line 137):

```swift
xpcClient.onSample = { [weak self] sample in
    guard let self else { return }
    store.addSample(sample)
    animator.update(sample: sample)
    historyIngestor?.ingest(sample)   // ← new
}
```

- [ ] **Step 3: Flush pending on terminate**

Add to `applicationWillTerminate(_:)` (or implement if absent):

```swift
func applicationWillTerminate(_ notification: Notification) {
    historyIngestor?.flushPending()
}
```

- [ ] **Step 4: Build + run existing tests**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: all existing tests still pass + the new history tests.

- [ ] **Step 5: Manual smoke test**

```bash
xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -configuration Release \
  -derivedDataPath build build \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=K38MBRNKAT ONLY_ACTIVE_ARCH=NO
pkill -9 -x MacSlowCooker || true
ditto build/Build/Products/Release/MacSlowCooker.app /Applications/MacSlowCooker.app
sudo launchctl kickstart -k system/com.macslowcooker.helper
open /Applications/MacSlowCooker.app
sleep 360   # 6 min so first 5-min bucket flushes
sqlite3 ~/Library/Application\ Support/MacSlowCooker/history.sqlite \
  "SELECT * FROM samples_5min;"
```
Expected: at least one row.

- [ ] **Step 6: Commit**

```bash
git add MacSlowCooker/AppDelegate.swift
git commit -m "feat(history): ingest live samples into HistoryStore from AppDelegate"
```

---

### Task 7: MRTGGraphView — single-panel renderer

**Files:**
- Create: `MacSlowCooker/MRTGGraphView.swift`

Single-pane filled-area graph with grid + axis labels, configured by metric and time range. Pure view — caller passes pre-fetched `[HistoryRecord]` and a metric selector.

- [ ] **Step 1: Define metric selector enum at top of new file**

```swift
import SwiftUI

enum HistoryMetric: String, CaseIterable, Identifiable {
    case gpu, temp, power, fan
    var id: String { rawValue }

    var label: String {
        switch self {
        case .gpu: return "GPU %"
        case .temp: return "SoC Temp °C"
        case .power: return "Power W"
        case .fan: return "Fan RPM"
        }
    }

    /// Suggested fixed Y-axis upper bound; if nil, auto-scale.
    var yMaxHint: Double? {
        switch self {
        case .gpu: return 100
        case .temp: return 110
        case .power: return nil
        case .fan: return nil
        }
    }

    func value(_ r: HistoryRecord) -> Double? {
        switch self {
        case .gpu:   return r.gpuPct
        case .temp:  return r.socTempC
        case .power: return r.powerW
        case .fan:   return r.fanRPM
        }
    }
}
```

- [ ] **Step 2: Add the Canvas-based view**

Append to the same file:

```swift
struct MRTGGraphView: View {
    let records: [HistoryRecord]
    let metric: HistoryMetric
    let granularity: HistoryGranularity
    let nowTs: Int

    private var rangeStart: Int { nowTs - granularity.retentionSeconds }
    private var rangeEnd: Int   { nowTs }

    private var yMax: Double {
        if let hint = metric.yMaxHint { return hint }
        let vs = records.compactMap(metric.value)
        return max((vs.max() ?? 1) * 1.1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(metric.label) — \(rangeLabel)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer()
                if let last = records.last.flatMap(metric.value) {
                    Text(String(format: "now: %.1f", last))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Canvas { ctx, size in
                drawGrid(ctx, size: size)
                drawSeries(ctx, size: size)
            }
            .frame(height: 90)
            .background(Color(white: 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var rangeLabel: String {
        switch granularity {
        case .fiveMin:   return "Last 24 h"
        case .thirtyMin: return "Last 7 d"
        case .twoHour:   return "Last 31 d"
        case .oneDay:    return "Last 400 d"
        }
    }

    private func x(forTs ts: Int, in size: CGSize) -> CGFloat {
        let span = max(rangeEnd - rangeStart, 1)
        return CGFloat(ts - rangeStart) / CGFloat(span) * size.width
    }

    private func y(forValue v: Double, in size: CGSize) -> CGFloat {
        size.height - CGFloat(min(v, yMax) / yMax) * size.height
    }

    private func drawGrid(_ ctx: GraphicsContext, size: CGSize) {
        let lineColor = Color(white: 0.2)
        for i in 1..<5 {
            let yy = size.height * CGFloat(i) / 5
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yy))
            path.addLine(to: CGPoint(x: size.width, y: yy))
            ctx.stroke(path, with: .color(lineColor), lineWidth: 0.5)
        }
    }

    private func drawSeries(_ ctx: GraphicsContext, size: CGSize) {
        let pts: [(CGFloat, CGFloat)] = records.compactMap { r in
            guard let v = metric.value(r) else { return nil }
            return (x(forTs: r.ts, in: size), y(forValue: v, in: size))
        }
        guard !pts.isEmpty else { return }

        // filled area
        var area = Path()
        area.move(to: CGPoint(x: pts[0].0, y: size.height))
        for p in pts { area.addLine(to: CGPoint(x: p.0, y: p.1)) }
        area.addLine(to: CGPoint(x: pts.last!.0, y: size.height))
        area.closeSubpath()
        ctx.fill(area, with: .color(.green.opacity(0.35)))

        // line on top
        var line = Path()
        line.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for p in pts.dropFirst() { line.addLine(to: CGPoint(x: p.0, y: p.1)) }
        ctx.stroke(line, with: .color(.green), lineWidth: 1.0)
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet`
Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add MacSlowCooker/MRTGGraphView.swift project.yml MacSlowCooker.xcodeproj
git commit -m "feat(history): MRTGGraphView Canvas renderer for one metric × one range"
```

---

### Task 8: HistoryView — tabbed 4×4 layout

**Files:**
- Create: `MacSlowCooker/HistoryView.swift`

- [ ] **Step 1: Add an `@Observable` view-model that loads ranges**

```swift
import SwiftUI
import Observation

@MainActor
@Observable
final class HistoryViewModel {
    private let store: HistoryStore
    private(set) var byGranularity: [HistoryGranularity: [HistoryRecord]] = [:]
    private(set) var nowTs: Int = Int(Date().timeIntervalSince1970)

    init(store: HistoryStore) { self.store = store }

    func reload() {
        nowTs = Int(Date().timeIntervalSince1970)
        var out: [HistoryGranularity: [HistoryRecord]] = [:]
        for g in HistoryGranularity.allCases {
            let since = nowTs - g.retentionSeconds
            out[g] = (try? store.query(granularity: g, sinceTs: since, untilTs: nowTs)) ?? []
        }
        byGranularity = out
    }
}
```

- [ ] **Step 2: Add the root view**

Append:

```swift
struct HistoryView: View {
    @Bindable var model: HistoryViewModel
    @State private var selectedMetric: HistoryMetric = .gpu

    var body: some View {
        VStack(spacing: 8) {
            Picker("Metric", selection: $selectedMetric) {
                ForEach(HistoryMetric.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(HistoryGranularity.allCases, id: \.self) { g in
                        MRTGGraphView(
                            records: model.byGranularity[g] ?? [],
                            metric: selectedMetric,
                            granularity: g,
                            nowTs: model.nowTs
                        )
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .background(Color(white: 0.04))
        .onAppear { model.reload() }
        .task {
            // refresh every 30s while window is open
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                model.reload()
            }
        }
    }
}
```

- [ ] **Step 3: Build**

Same command as Task 7 Step 3. Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add MacSlowCooker/HistoryView.swift project.yml MacSlowCooker.xcodeproj
git commit -m "feat(history): tabbed HistoryView with 4 stacked time ranges per metric"
```

---

### Task 9: HistoryWindowController + menu wiring

**Files:**
- Create: `MacSlowCooker/HistoryWindowController.swift`
- Modify: `MacSlowCooker/AppDelegate.swift`

- [ ] **Step 1: Implement window controller**

```swift
import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private let model: HistoryViewModel

    init(store: HistoryStore) {
        self.model = HistoryViewModel(store: store)
    }

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            model.reload()
            return
        }
        let host = NSHostingController(rootView: HistoryView(model: model))
        let w = NSWindow(contentViewController: host)
        w.title = "MacSlowCooker — History"
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 560, height: 600))
        w.center()
        w.isReleasedWhenClosed = false
        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 2: Add the property and menu item in AppDelegate**

In `AppDelegate.swift`:

```swift
private lazy var historyController: HistoryWindowController? =
    historyStore.map { HistoryWindowController(store: $0) }

@objc private func openHistoryWindow() {
    historyController?.showWindow()
}
```

Then in the menu-construction code (find where Preferences is added — likely a `buildMenu()` or similar), add an "History…" item with key equivalent `H`:

```swift
let historyItem = NSMenuItem(title: "History…",
                             action: #selector(openHistoryWindow),
                             keyEquivalent: "h")
historyItem.target = self
appMenu.addItem(historyItem)
```

(Place near Preferences. If menu wiring is elsewhere, follow the existing Preferences pattern verbatim.)

- [ ] **Step 3: Build + manual smoke test**

```bash
xcodegen generate
xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -configuration Release \
  -derivedDataPath build build \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=K38MBRNKAT ONLY_ACTIVE_ARCH=NO
pkill -9 -x MacSlowCooker || true
ditto build/Build/Products/Release/MacSlowCooker.app /Applications/MacSlowCooker.app
open /Applications/MacSlowCooker.app
```
Open the History window via the menu (or `Cmd+H`). Expected: 4 stacked panels render. After the first 5-min flush, the Daily panel shows a tick.

- [ ] **Step 4: Commit**

```bash
git add MacSlowCooker/HistoryWindowController.swift MacSlowCooker/AppDelegate.swift project.yml MacSlowCooker.xcodeproj
git commit -m "feat(history): History window + menu item"
```

---

### Task 10: Docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add a "History subsystem" subsection to CLAUDE.md "Architecture"**

Insert after the existing app-side bullet list, a short paragraph describing:
- App-side ingest (helper unchanged).
- 4 round-robin tables under `~/Library/Application Support/MacSlowCooker/history.sqlite`.
- Buckets: 5-min / 30-min / 2-hour / 1-day with retentions 24h / 7d / 31d / 400d.
- Pure aggregator in `Shared/HistoryAggregator.swift`; pure-helper pattern preserved.

Keep it under 12 lines — the file is reference-density.

- [ ] **Step 2: Add a `## [Unreleased]` entry to CHANGELOG.md**

Under "Added":
- "History window: MRTG-style Daily / Weekly / Monthly / Yearly graphs for GPU / Temp / Power / Fan."
- "Local round-robin SQLite store at `~/Library/Application Support/MacSlowCooker/history.sqlite`."

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md CHANGELOG.md
git commit -m "docs(history): document history subsystem and changelog"
```

---

## Validation

- [ ] All 53 existing tests still pass.
- [ ] New tests pass: `HistoryAggregatorTests` (5), `HistoryStoreTests` (3), `HistoryIngestorTests` (2).
- [ ] After ~6 min uptime, `sqlite3 ~/Library/Application\ Support/MacSlowCooker/history.sqlite "SELECT COUNT(*) FROM samples_5min;"` returns ≥ 1.
- [ ] History window opens, 4 panels render, "now: …" label updates.
- [ ] Killing and relaunching the app retains earlier rows (DB persists).
- [ ] Fanless-Mac path: on a MacBook Air M-series the Fan tab renders empty graphs (no crash).
- [ ] Universal Binary build still produces both arm64 and x86_64 slices: `lipo -info build/Build/Products/Release/MacSlowCooker.app/Contents/MacOS/MacSlowCooker`.
