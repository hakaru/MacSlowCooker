# Prometheus Exporter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose live MacSlowCooker metrics (GPU%, power, temp, fan, thermal pressure, helper-up) over HTTP in Prometheus text exposition format so external scrapers (Prometheus, Grafana Agent, VictoriaMetrics) can collect them.

**Architecture:** App-side. A new `PrometheusExporter` class wraps `Network.framework`'s `NWListener` on TCP. It owns a snapshot of the latest `GPUSample` plus the helper-connection flag, both updated from the existing `xpcClient.onSample` / `onConnected` / `onDisconnected` callbacks in `AppDelegate`. The text format is produced by a pure `PrometheusFormatter` in `Shared/`, fully unit-tested. Settings expose three new keys (enable / port / bind-all) gated through Preferences. Default is OFF (opt-in) and loopback-only when on, so the macOS firewall prompt only fires when the user explicitly enables remote access.

**Tech Stack:**
- Swift 6, `Network.framework` (`NWListener`, `NWConnection`, `NWParameters`)
- `Foundation` for `URLSession` (test client only)
- Reuses existing `Settings` (`@Observable` + `AsyncStream<Void>`) and `XPCClient` callback wiring
- Tests use XCTest; the integration test spins a real loopback socket on a randomized port

**Out of scope:**
- HTTPS / TLS (Prometheus convention: front with reverse proxy if you need it)
- Authentication / Bearer tokens
- HTTP/1.1 keepalive (every response sets `Connection: close`)
- Multi-request pipelining
- Historical aggregates (Prometheus does its own scraping/storage)
- IPv6 (NWListener gets it for free; we just don't actively test it)

---

## File Structure

**Create (new):**
- `Shared/PrometheusFormatter.swift` — pure: `GPUSample?` + `Bool` → exposition string.
- `MacSlowCooker/PrometheusExporter.swift` — `final class` wrapping `NWListener`. Public API: `start(port:loopbackOnly:)`, `stop()`, `update(sample:)`, `update(helperConnected:)`. Internal serial queue protects mutable snapshot state.
- `MacSlowCookerTests/PrometheusFormatterTests.swift` — pure formatter tests.
- `MacSlowCookerTests/PrometheusExporterTests.swift` — async integration test: start exporter on a random port, fetch `/metrics` via `URLSession`, assert HTTP 200 + expected metric lines; fetch `/nope` and assert 404.

**Modify:**
- `MacSlowCooker/Settings.swift` — three new keys: `prometheusEnabled: Bool` (default `false`), `prometheusPort: Int` (default `9091`), `prometheusBindAll: Bool` (default `false`). Add to `resetToDefaults()`.
- `MacSlowCooker/PreferencesWindowController.swift` — new `Section("Prometheus Exporter")` in `PreferencesView` with toggle + port stepper + bind-all toggle.
- `MacSlowCooker/AppDelegate.swift` — own a `PrometheusExporter`, observe Settings changes via the existing `settingsObservationTask`, push `onSample` / `onConnected` / `onDisconnected` updates into it. Stop on `applicationWillTerminate`.
- `CLAUDE.md` — add a "Prometheus exporter" subsection under Architecture.
- `CHANGELOG.md` — `[Unreleased]` entry.

**Conventions followed:**
- Pure logic in `Shared/`, IO-bound code in `MacSlowCooker/` (matches the SMC / IOAccelerator / HistoryAggregator pattern).
- New files require `xcodegen generate` (per CLAUDE.md "SourceKit false positives" section).
- Tests use `CODE_SIGNING_ALLOWED=NO`.

---

### Task 1: PrometheusFormatter (pure)

**Files:**
- Create: `Shared/PrometheusFormatter.swift`
- Create: `MacSlowCookerTests/PrometheusFormatterTests.swift`

Use TDD throughout.

- [ ] **Step 1: Write failing test — full sample, helper connected**

`MacSlowCookerTests/PrometheusFormatterTests.swift`:

```swift
import XCTest
@testable import MacSlowCooker

final class PrometheusFormatterTests: XCTestCase {
    func testExpositionWithFullSample() {
        let sample = GPUSample(
            timestamp: Date(timeIntervalSince1970: 1778231262),
            gpuUsage: 0.42,
            temperature: 67.2,
            thermalPressure: .nominal,
            power: 8.4,
            anePower: 1.6,
            aneUsage: nil,
            fanRPM: [1850, 2100]
        )
        let body = PrometheusFormatter.exposition(sample: sample, helperConnected: true, version: "1.0.0")
        // Expected lines (order preserved by the formatter):
        XCTAssertTrue(body.contains("# TYPE macslowcooker_gpu_usage_ratio gauge"))
        XCTAssertTrue(body.contains("\nmacslowcooker_gpu_usage_ratio 0.42\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_gpu_power_watts 8.4\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_ane_power_watts 1.6\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_temperature_celsius 67.2\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_thermal_pressure 0\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_fan_rpm{fan=\"0\"} 1850\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_fan_rpm{fan=\"1\"} 2100\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_helper_connected 1\n"))
        XCTAssertTrue(body.contains("\nmacslowcooker_build_info{version=\"1.0.0\"} 1\n"))
    }
}
```

- [ ] **Step 2: Run test, verify failure**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/PrometheusFormatterTests 2>&1 | tail -10`
Expected: FAIL (`PrometheusFormatter` undefined).

- [ ] **Step 3: Write `Shared/PrometheusFormatter.swift`**

```swift
import Foundation

/// Pure renderer for Prometheus text exposition format (version 0.0.4).
/// Reference: https://prometheus.io/docs/instrumenting/exposition_formats/
enum PrometheusFormatter {
    /// Render the current snapshot to an exposition string. Missing values
    /// (e.g. fanless Macs, no power data, helper down) cause those metric
    /// lines to be omitted entirely — Prometheus prefers absence over fake
    /// zeros for "unknown".
    static func exposition(sample: GPUSample?, helperConnected: Bool, version: String) -> String {
        var out = ""

        // build_info — always emitted, identifies this binary.
        out += "# HELP macslowcooker_build_info Build metadata as a constant 1.\n"
        out += "# TYPE macslowcooker_build_info gauge\n"
        out += "macslowcooker_build_info{version=\"\(version)\"} 1\n"

        // helper_connected — always emitted (0 or 1).
        out += "# HELP macslowcooker_helper_connected Whether the privileged HelperTool XPC connection is up (0 or 1).\n"
        out += "# TYPE macslowcooker_helper_connected gauge\n"
        out += "macslowcooker_helper_connected \(helperConnected ? 1 : 0)\n"

        guard let s = sample else { return out }

        // gpu_usage_ratio (0..1).
        out += "# HELP macslowcooker_gpu_usage_ratio GPU usage as a 0..1 ratio (1 - idle_ratio from powermetrics).\n"
        out += "# TYPE macslowcooker_gpu_usage_ratio gauge\n"
        out += "macslowcooker_gpu_usage_ratio \(format(s.gpuUsage))\n"

        if let p = s.power {
            out += "# HELP macslowcooker_gpu_power_watts Current GPU power draw in watts.\n"
            out += "# TYPE macslowcooker_gpu_power_watts gauge\n"
            out += "macslowcooker_gpu_power_watts \(format(p))\n"
        }

        if let a = s.anePower {
            out += "# HELP macslowcooker_ane_power_watts Current Apple Neural Engine power draw in watts.\n"
            out += "# TYPE macslowcooker_ane_power_watts gauge\n"
            out += "macslowcooker_ane_power_watts \(format(a))\n"
        }

        if let t = s.temperature {
            out += "# HELP macslowcooker_temperature_celsius SoC temperature in degrees Celsius (averaged across die / proximity sensors).\n"
            out += "# TYPE macslowcooker_temperature_celsius gauge\n"
            out += "macslowcooker_temperature_celsius \(format(t))\n"
        }

        if let tp = s.thermalPressure {
            out += "# HELP macslowcooker_thermal_pressure Thermal pressure level (0=Nominal, 1=Fair, 2=Serious, 3=Critical).\n"
            out += "# TYPE macslowcooker_thermal_pressure gauge\n"
            out += "macslowcooker_thermal_pressure \(level(of: tp))\n"
        }

        if let fans = s.fanRPM, !fans.isEmpty {
            out += "# HELP macslowcooker_fan_rpm Fan rotation speed in RPM, labelled by fan index.\n"
            out += "# TYPE macslowcooker_fan_rpm gauge\n"
            for (i, rpm) in fans.enumerated() {
                out += "macslowcooker_fan_rpm{fan=\"\(i)\"} \(format(rpm))\n"
            }
        }

        return out
    }

    /// Trim trailing zeros and decimal point. Prometheus accepts plain numeric
    /// floats; minimising width keeps the response small.
    private static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return String(format: "%g", v)
        }
        return String(format: "%g", v)
    }

    private static func level(of pressure: ThermalPressure) -> Int {
        switch pressure {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        }
    }
}
```

- [ ] **Step 4: Run test, verify pass**

Run: `xcodegen generate && xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/PrometheusFormatterTests/testExpositionWithFullSample 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5: Add failing test — fanless Mac, missing optional fields**

Append to `PrometheusFormatterTests.swift`:

```swift
func testExpositionFanlessMacOmitsFanLines() {
    let sample = GPUSample(
        timestamp: Date(timeIntervalSince1970: 1778231262),
        gpuUsage: 0.10,
        temperature: nil,
        thermalPressure: nil,
        power: nil,
        anePower: nil,
        aneUsage: nil,
        fanRPM: nil
    )
    let body = PrometheusFormatter.exposition(sample: sample, helperConnected: true, version: "1.0.0")
    XCTAssertTrue(body.contains("\nmacslowcooker_gpu_usage_ratio 0.1\n"))
    XCTAssertFalse(body.contains("macslowcooker_fan_rpm"))
    XCTAssertFalse(body.contains("macslowcooker_temperature_celsius"))
    XCTAssertFalse(body.contains("macslowcooker_gpu_power_watts"))
    XCTAssertFalse(body.contains("macslowcooker_ane_power_watts"))
    XCTAssertFalse(body.contains("macslowcooker_thermal_pressure"))
}

func testExpositionHelperDownEmitsOnlyMetadata() {
    let body = PrometheusFormatter.exposition(sample: nil, helperConnected: false, version: "1.2.3")
    XCTAssertTrue(body.contains("\nmacslowcooker_helper_connected 0\n"))
    XCTAssertTrue(body.contains("macslowcooker_build_info{version=\"1.2.3\"} 1"))
    XCTAssertFalse(body.contains("macslowcooker_gpu_usage_ratio"))
}
```

- [ ] **Step 6: Run all formatter tests, verify pass**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/PrometheusFormatterTests 2>&1 | tail -10`
Expected: 3 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Shared/PrometheusFormatter.swift MacSlowCookerTests/PrometheusFormatterTests.swift project.yml MacSlowCooker.xcodeproj
git commit -m "feat(prometheus): pure exposition-format renderer"
```

---

### Task 2: Settings keys

**Files:**
- Modify: `MacSlowCooker/Settings.swift`

- [ ] **Step 1: Add three new keys to the `Keys` enum**

In `Settings.swift`, in the `Keys` enum block:

```swift
enum Keys {
    static let potStyle               = "potStyle"
    static let flameAnimation         = "flameAnimation"
    static let boilingTrigger         = "boilingTrigger"
    static let floatAboveOtherWindows = "floatAboveOtherWindows"
    static let prometheusEnabled      = "prometheusEnabled"
    static let prometheusPort         = "prometheusPort"
    static let prometheusBindAll      = "prometheusBindAll"
}
```

- [ ] **Step 2: Add three observable properties**

Insert after `floatAboveOtherWindows`:

```swift
var prometheusEnabled: Bool = false {
    didSet { defaults.set(prometheusEnabled, forKey: Keys.prometheusEnabled) }
}

var prometheusPort: Int = 9091 {
    didSet { defaults.set(prometheusPort, forKey: Keys.prometheusPort) }
}

var prometheusBindAll: Bool = false {
    didSet { defaults.set(prometheusBindAll, forKey: Keys.prometheusBindAll) }
}
```

- [ ] **Step 3: Update `resetToDefaults()`**

Append to the `resetToDefaults()` body:

```swift
prometheusEnabled = false
prometheusPort    = 9091
prometheusBindAll = false
```

- [ ] **Step 4: Update `init(defaults:)` to load the keys**

Append to the bottom of `init(defaults:)`:

```swift
self.prometheusEnabled = (defaults.object(forKey: Keys.prometheusEnabled) as? Bool) ?? false
let storedPort = defaults.integer(forKey: Keys.prometheusPort)
self.prometheusPort    = (1024...65535).contains(storedPort) ? storedPort : 9091
self.prometheusBindAll = (defaults.object(forKey: Keys.prometheusBindAll) as? Bool) ?? false
```

(`defaults.integer(forKey:)` returns 0 when the key is missing; the range check both handles "first launch" and protects against an edited plist value outside the unprivileged port range.)

- [ ] **Step 5: Run the test suite to confirm no regression**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: all tests pass (no Settings tests exist; this is a regression sanity check).

- [ ] **Step 6: Commit**

```bash
git add MacSlowCooker/Settings.swift
git commit -m "feat(prometheus): settings keys (enabled, port, bindAll)"
```

---

### Task 3: PrometheusExporter (NWListener + handler)

**Files:**
- Create: `MacSlowCooker/PrometheusExporter.swift`
- Create: `MacSlowCookerTests/PrometheusExporterTests.swift`

This is the largest task. The exporter is a regular `final class` whose mutable state (`listener`, `latestSample`, `helperConnected`) is protected by a private serial `DispatchQueue`. It is *not* `@MainActor` because the `NWListener` callbacks fire on its own queue.

- [ ] **Step 1: Write failing integration test**

`MacSlowCookerTests/PrometheusExporterTests.swift`:

```swift
import XCTest
@testable import MacSlowCooker

final class PrometheusExporterTests: XCTestCase {
    func testServeMetricsEndpoint() async throws {
        let exporter = PrometheusExporter(version: "1.2.3")
        // Random unprivileged port in 49152..65535 (IANA ephemeral range).
        let port = UInt16.random(in: 49152...65535)
        try exporter.start(port: port, loopbackOnly: true)
        defer { exporter.stop() }

        // Push a snapshot.
        let sample = GPUSample(
            timestamp: Date(timeIntervalSince1970: 1778231262),
            gpuUsage: 0.5,
            temperature: 60,
            thermalPressure: nil,
            power: 12,
            anePower: nil,
            aneUsage: nil,
            fanRPM: [1500]
        )
        exporter.update(sample: sample)
        exporter.update(helperConnected: true)

        // Allow the listener to settle.
        try await Task.sleep(for: .milliseconds(150))

        let url = URL(string: "http://127.0.0.1:\(port)/metrics")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("macslowcooker_gpu_usage_ratio 0.5"))
        XCTAssertTrue(body.contains("macslowcooker_helper_connected 1"))
        XCTAssertTrue(body.contains("macslowcooker_fan_rpm{fan=\"0\"} 1500"))
        XCTAssertTrue(body.contains("macslowcooker_build_info{version=\"1.2.3\"} 1"))
    }

    func testUnknownPathReturns404() async throws {
        let exporter = PrometheusExporter(version: "1.0.0")
        let port = UInt16.random(in: 49152...65535)
        try exporter.start(port: port, loopbackOnly: true)
        defer { exporter.stop() }
        try await Task.sleep(for: .milliseconds(150))

        let url = URL(string: "http://127.0.0.1:\(port)/nope")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 404)
    }
}
```

- [ ] **Step 2: Run test, verify failure**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/PrometheusExporterTests 2>&1 | tail -10`
Expected: FAIL (`PrometheusExporter` undefined).

- [ ] **Step 3: Implement `PrometheusExporter`**

`MacSlowCooker/PrometheusExporter.swift`:

```swift
import Foundation
import Network
import os

/// HTTP/1.1 server exposing `GET /metrics` in Prometheus text exposition
/// format. Not thread-safe across instances; mutable state inside one
/// instance is serialized through a private dispatch queue.
final class PrometheusExporter {
    private let version: String
    private let log = OSLog(subsystem: "com.macslowcooker.app", category: "PrometheusExporter")
    private let queue = DispatchQueue(label: "com.macslowcooker.prometheus-exporter")

    private var listener: NWListener?
    private var latestSample: GPUSample?
    private var helperConnected: Bool = false

    init(version: String) { self.version = version }

    deinit { listener?.cancel() }

    /// Start listening on `port`. If `loopbackOnly` is true the listener
    /// binds only to the loopback interface (no firewall prompt; only
    /// reachable from the same Mac).
    func start(port: UInt16, loopbackOnly: Bool) throws {
        // Stop any previous listener first.
        stop()

        let params = NWParameters.tcp
        if loopbackOnly { params.requiredInterfaceType = .loopback }
        // Disable IPv6 on loopback to keep the URL stable (`127.0.0.1`)
        // — Prometheus scrape configs typically use the IPv4 form.
        if loopbackOnly {
            if let ipOpt = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOpt.version = .v4
            }
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "PrometheusExporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                os_log("Prometheus listener ready on %d", log: self.log, type: .info, Int(port))
            case .failed(let err):
                os_log("Prometheus listener failed: %{public}@", log: self.log, type: .error, "\(err)")
            default:
                break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func update(sample: GPUSample?) {
        queue.async { [weak self] in self?.latestSample = sample }
    }

    func update(helperConnected: Bool) {
        queue.async { [weak self] in self?.helperConnected = helperConnected }
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { conn.cancel(); return }
            if let error {
                os_log("recv error: %{public}@", log: self.log, type: .info, "\(error)")
                conn.cancel(); return
            }
            let path = data.flatMap(Self.parseRequestPath) ?? ""
            let response: Data = self.makeResponse(forPath: path)
            conn.send(content: response, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    /// Extract the request-target from the start-line of an HTTP/1.x request.
    /// Returns nil for malformed input. Cap at 1024 bytes — request lines
    /// longer than that are spam.
    static func parseRequestPath(in data: Data) -> String? {
        guard let crlf = data.firstRange(of: Data([0x0d, 0x0a])) else { return nil }
        let line = data[..<crlf.lowerBound]
        guard line.count <= 1024,
              let str = String(data: line, encoding: .utf8) else { return nil }
        let parts = str.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    private func makeResponse(forPath path: String) -> Data {
        // `latestSample` and `helperConnected` are only accessed on `queue`,
        // and `handle(_:)` is called from `queue`, so direct reads are safe.
        if path == "/metrics" {
            let body = PrometheusFormatter.exposition(
                sample: latestSample,
                helperConnected: helperConnected,
                version: version
            )
            return Self.makeHTTP(status: "200 OK",
                                  contentType: "text/plain; version=0.0.4; charset=utf-8",
                                  body: body)
        }
        return Self.makeHTTP(status: "404 Not Found",
                              contentType: "text/plain; charset=utf-8",
                              body: "Not Found\n")
    }

    private static func makeHTTP(status: String, contentType: String, body: String) -> Data {
        var head = ""
        head += "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        let bodyData = body.data(using: .utf8) ?? Data()
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data()
        out.append(head.data(using: .utf8) ?? Data())
        out.append(bodyData)
        return out
    }
}
```

- [ ] **Step 4: Run xcodegen + the integration tests**

Run:
```
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/PrometheusExporterTests 2>&1 | tail -10
```
Expected: 2 tests pass.

If the test fails with a port-bind error, the random port collided. Re-run; the port is randomized per call.

- [ ] **Step 5: Run the full suite to confirm no regression**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add MacSlowCooker/PrometheusExporter.swift MacSlowCookerTests/PrometheusExporterTests.swift project.yml MacSlowCooker.xcodeproj
git commit -m "feat(prometheus): NWListener-based HTTP exporter for /metrics"
```

---

### Task 4: Preferences UI

**Files:**
- Modify: `MacSlowCooker/PreferencesWindowController.swift`

- [ ] **Step 1: Add a new `Section("Prometheus Exporter")` to `PreferencesView`**

Insert after the existing `Section("Window")` block in the `Form` body:

```swift
Section("Prometheus Exporter") {
    Toggle("Enable", isOn: $settings.prometheusEnabled)
    Stepper(value: $settings.prometheusPort, in: 1024...65535) {
        HStack {
            Text("Port")
            Spacer()
            Text("\(settings.prometheusPort)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
    Toggle("Bind to all interfaces (allows remote scraping)", isOn: $settings.prometheusBindAll)
        .disabled(!settings.prometheusEnabled)
    if settings.prometheusEnabled {
        Text("http://\(settings.prometheusBindAll ? "0.0.0.0" : "127.0.0.1"):\(settings.prometheusPort)/metrics")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
```

- [ ] **Step 2: Bump the Preferences window default content size**

In `PreferencesWindowController.init(...)`:

```swift
window.setContentSize(NSSize(width: 420, height: 440))   // was 320 — accommodate the new section
```

- [ ] **Step 3: Build and confirm UI compiles**

Run: `xcodegen generate && xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add MacSlowCooker/PreferencesWindowController.swift MacSlowCooker.xcodeproj
git commit -m "feat(prometheus): preferences UI section (toggle, port, bind-all)"
```

---

### Task 5: AppDelegate wiring

**Files:**
- Modify: `MacSlowCooker/AppDelegate.swift`

The exporter is owned by `AppDelegate`. It is reconfigured (started / restarted / stopped) whenever the relevant settings change. Sample and helper-connection updates piggy-back on the existing `xpcClient` callbacks.

- [ ] **Step 1: Add a `prometheusExporter` property and a configuration helper**

Near the other lazy/private properties (around the `historyController` block):

```swift
private let prometheusExporter = PrometheusExporter(
    version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
)

private func configurePrometheusExporter() {
    prometheusExporter.stop()
    guard settings.prometheusEnabled else { return }
    do {
        try prometheusExporter.start(
            port: UInt16(settings.prometheusPort),
            loopbackOnly: !settings.prometheusBindAll
        )
    } catch {
        os_log("PrometheusExporter start failed: %{public}@", log: log, type: .error, String(describing: error))
    }
}
```

- [ ] **Step 2: Push samples and helper state into the exporter from the existing XPC callbacks**

Modify the `xpcClient.onSample` block in `connectXPC()` to also push to the exporter:

```swift
xpcClient.onSample = { [weak self] sample in
    guard let self else { return }
    store.addSample(sample)
    animator.update(sample: sample)
    historyIngestor?.ingest(sample)
    prometheusExporter.update(sample: sample)
}
xpcClient.onConnected = { [weak self] in
    self?.store.setConnected(true)
    self?.animator.setConnected(true)
    self?.prometheusExporter.update(helperConnected: true)
    os_log("XPC connected", log: log, type: .info)
}
xpcClient.onDisconnected = { [weak self] in
    self?.store.setConnected(false)
    self?.animator.setConnected(false)
    self?.prometheusExporter.update(helperConnected: false)
    os_log("XPC disconnected", log: log, type: .info)
}
```

(Replace each existing block with the augmented version. Keep the `os_log` lines for the connect/disconnect states.)

- [ ] **Step 3: Configure the exporter at launch and after every settings change**

Find `applicationDidFinishLaunching(_:)` and add `configurePrometheusExporter()` near the bottom of that function (after existing setup like `connectXPC()`). Find `observeSettings()` (the `settingsObservationTask` initializer) and add a call to `self.configurePrometheusExporter()` inside the `for await _ in settings.changes { ... }` body, alongside the existing `animator.update(...)` style calls.

If `observeSettings()` currently looks like:

```swift
for await _ in settings.changes {
    animator.applySettings(settings)
}
```

extend it to:

```swift
for await _ in settings.changes {
    animator.applySettings(settings)
    self.configurePrometheusExporter()
}
```

(Match the actual existing body — the key is to invoke `configurePrometheusExporter()` after every settings yield.)

- [ ] **Step 4: Stop the exporter on terminate**

Extend `applicationWillTerminate(_:)`:

```swift
func applicationWillTerminate(_ notification: Notification) {
    historyIngestor?.flushPending()
    prometheusExporter.stop()
}
```

- [ ] **Step 5: Build + run all tests**

Run:
```
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: all tests pass (incl. the new Prometheus tests).

- [ ] **Step 6: Manual smoke test (deferred — user runs)**

These steps require deploying the signed Release build and toggling the new Setting from the UI:

```bash
xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -configuration Release \
  -derivedDataPath build build \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=K38MBRNKAT ONLY_ACTIVE_ARCH=NO
pkill -9 -x MacSlowCooker || true
ditto build/Build/Products/Release/MacSlowCooker.app /Applications/MacSlowCooker.app
open /Applications/MacSlowCooker.app
```

In Preferences → Prometheus Exporter, toggle Enable on. Then:

```bash
curl -s http://127.0.0.1:9091/metrics | head -30
```

Expected: a Prometheus-format response starting with `# HELP macslowcooker_build_info ...`, including non-zero `macslowcooker_helper_connected` and current `macslowcooker_gpu_usage_ratio`.

The implementer should NOT execute Step 6 — flag it for the user.

- [ ] **Step 7: Commit**

```bash
git add MacSlowCooker/AppDelegate.swift
git commit -m "feat(prometheus): wire exporter into AppDelegate (settings + sample stream)"
```

---

### Task 6: Docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add a "Prometheus exporter" subsection to CLAUDE.md**

Insert after the existing "History subsystem" paragraph in the Architecture section. Keep it terse (under ~10 lines):

```
**Prometheus exporter** (opt-in, off by default). When enabled in Preferences,
`PrometheusExporter` (an `NWListener` + manual HTTP/1.1 handler in
`MacSlowCooker/PrometheusExporter.swift`) exposes `GET /metrics` in the
Prometheus text exposition format, populated from the same XPC sample stream
that feeds the Dock icon and history store. By default it binds 127.0.0.1
only; the "Bind to all interfaces" toggle opens it up for remote scraping
(triggers the macOS firewall prompt). Pure formatting lives in
`Shared/PrometheusFormatter.swift` and is fully unit-tested. Default port:
9091. Auth: none (Prometheus convention; front with a reverse proxy if
needed).
```

- [ ] **Step 2: Add a `[Unreleased]` entry to CHANGELOG.md**

Under the existing `[Unreleased]` → `Added` block, append:

```
- Prometheus exporter (opt-in via Preferences) — exposes live GPU/temp/power/fan/thermal/helper metrics on `http://127.0.0.1:9091/metrics` for Prometheus, Grafana Agent, and other compatible scrapers.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md CHANGELOG.md
git commit -m "docs(prometheus): document exporter subsystem and changelog"
```

---

## Validation

- [ ] All pre-existing tests still pass.
- [ ] New tests pass: `PrometheusFormatterTests` (3), `PrometheusExporterTests` (2).
- [ ] Universal Binary is preserved: `lipo -info build/Build/Products/Release/MacSlowCooker.app/Contents/MacOS/MacSlowCooker` reports `x86_64 arm64`.
- [ ] After enabling the exporter in Preferences and running for a few seconds, `curl -s http://127.0.0.1:9091/metrics` returns a non-empty Prometheus exposition body that includes `macslowcooker_gpu_usage_ratio`.
- [ ] Disabling the exporter in Preferences stops it within ~1 second; subsequent `curl` calls fail with connection-refused.
- [ ] Toggling "Bind to all interfaces" prompts the macOS Application Firewall (only confirmed visually by the user).
- [ ] Helper-down state is reflected: `macslowcooker_helper_connected 0` after `sudo launchctl stop system/com.macslowcooker.helper` followed by `curl /metrics`.
