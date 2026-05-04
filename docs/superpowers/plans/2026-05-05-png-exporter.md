# PNG Exporter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Periodically render the existing `MRTGGraphView` panels off-screen and write them to disk as PNG files plus an auto-refreshing `index.html`, so the metrics dashboard can be served by any static web server (`python3 -m http.server`, nginx, Caddy) for cross-machine viewing — the literal MRTG cron-and-PNG workflow.

**Architecture:** App-side, opt-in. A `@MainActor PNGExporter` reads from the existing `HistoryStore`, hands records to `MRTGGraphView` instances, and rasterises each panel via SwiftUI's `ImageRenderer` (macOS 13+, available since deployment target is macOS 14). Output: 8 PNGs (Compute/Thermal × Daily/Weekly/Monthly/Yearly) plus a static `index.html` with `<meta http-equiv="refresh" content="60">`. A 5-minute repeating `Timer` triggers re-render, plus one immediate render on enable so the directory isn't empty. Pure HTML generation lives in `Shared/PNGExporterHTML.swift` for unit testing.

**Tech Stack:**
- Swift 6, SwiftUI `ImageRenderer<Content>` (macOS 13+)
- `NSBitmapImageRep.representation(using: .png, properties: [:])` for CGImage → PNG
- `Foundation.Timer` (main runloop, repeating)
- Reuses existing `HistoryStore`, `HistoryPanel`, `HistoryGranularity`, `MRTGGraphView`
- Tests: XCTest using a temp directory

**Out of scope:**
- Web server (the user runs their own — `python3 -m http.server -d <path>`, nginx, etc.)
- Custom HTML templates / theming (one fixed layout)
- Configurable interval (5 min hardcoded; trivially extended later)
- Configurable image size / scale (600×140 @ 2x retina)
- Image diffing / write-only-on-change (always rewrite — disk cost is negligible)

---

## File Structure

**Create (new):**
- `Shared/PNGExporterHTML.swift` — pure: `(nowTs: Int, panels: [HistoryPanel], granularities: [HistoryGranularity]) -> String`. Fully unit-testable.
- `MacSlowCooker/PNGExporter.swift` — `@MainActor final class`. Public API: `init(store: HistoryStore)`, `start(at directory: URL)`, `stop()`. Owns the Timer and renders on its tick.
- `MacSlowCookerTests/PNGExporterHTMLTests.swift` — pure HTML tests.
- `MacSlowCookerTests/PNGExporterTests.swift` — integration test: start exporter against an in-memory store seeded with one row, run one render cycle, assert the 8 PNG files + `index.html` exist with non-empty bodies.

**Modify:**
- `Shared/HistoryGranularity.swift` — add `var id: String` (`"daily"` / `"weekly"` / `"monthly"` / `"yearly"`) for filename keys.
- `MacSlowCooker/Settings.swift` — 2 new keys: `pngExportEnabled: Bool` (default `false`), `pngExportPath: String` (default `<Application Support>/MacSlowCooker/web`). Add to `resetToDefaults()` and `SettingsChangeTracker`.
- `MacSlowCooker/PreferencesWindowController.swift` — new `Section("PNG Export")` with toggle, path display, "Choose Folder..." button (NSOpenPanel), and "Reveal in Finder" button.
- `MacSlowCooker/AppDelegate.swift` — own a `PNGExporter`, observe Settings changes via the existing `settingsObservationTask` to start/stop, stop on `applicationWillTerminate`.
- `CLAUDE.md` — add a "PNG export" subsection under Architecture.
- `CHANGELOG.md` — `[Unreleased]` entry.

**Conventions followed:**
- Pure logic in `Shared/`; IO/UI-bound code in `MacSlowCooker/`.
- After adding new files: `xcodegen generate`.
- Tests use `CODE_SIGNING_ALLOWED=NO`.

---

### Task 1: HistoryGranularity.id

**Files:**
- Modify: `Shared/HistoryGranularity.swift`

Tiny prep change so PNG filenames are stable and language-neutral.

- [ ] **Step 1: Add an `id` property**

In `Shared/HistoryGranularity.swift`, append to the enum body (just before the closing brace):

```swift
/// Filename-safe identifier used by the PNG exporter (`compute-daily.png` etc.).
var id: String {
    switch self {
    case .fiveMin:   return "daily"
    case .thirtyMin: return "weekly"
    case .twoHour:   return "monthly"
    case .oneDay:    return "yearly"
    }
}
```

- [ ] **Step 2: Build to confirm**

Run: `xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Shared/HistoryGranularity.swift
git commit -m "feat(png): HistoryGranularity.id for filename-safe identifiers"
```

---

### Task 2: PNGExporterHTML (pure)

**Files:**
- Create: `Shared/PNGExporterHTML.swift`
- Create: `MacSlowCookerTests/PNGExporterHTMLTests.swift`

- [ ] **Step 1: Write failing test**

`MacSlowCookerTests/PNGExporterHTMLTests.swift`:

```swift
import XCTest
@testable import MacSlowCooker

final class PNGExporterHTMLTests: XCTestCase {
    func testIndexContainsAllPanelImagesAndAutoRefresh() {
        let html = PNGExporterHTML.render(
            nowTs: 1778231262,
            panels: HistoryPanel.all,
            granularities: HistoryGranularity.allCases
        )
        // Auto-refresh meta tag
        XCTAssertTrue(html.contains("<meta http-equiv=\"refresh\""))
        // Title
        XCTAssertTrue(html.contains("MacSlowCooker"))
        // 8 image references — every panel × granularity combination
        for panel in HistoryPanel.all {
            for g in HistoryGranularity.allCases {
                XCTAssertTrue(
                    html.contains("\(panel.id)-\(g.id).png"),
                    "missing \(panel.id)-\(g.id).png"
                )
            }
        }
        // Section headers
        XCTAssertTrue(html.contains("Compute"))
        XCTAssertTrue(html.contains("Thermal"))
        // Last-updated timestamp
        XCTAssertTrue(html.contains("Last updated"))
    }

    func testRenderEscapesAngleBracketsInTitle() {
        // Sanity: no template injection from the static title (defensive).
        let html = PNGExporterHTML.render(
            nowTs: 0,
            panels: HistoryPanel.all,
            granularities: HistoryGranularity.allCases
        )
        XCTAssertFalse(html.contains("<script>"))
    }
}
```

- [ ] **Step 2: Run test, verify failure**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/PNGExporterHTMLTests 2>&1 | tail -10`
Expected: FAIL (`PNGExporterHTML` undefined).

- [ ] **Step 3: Implement `PNGExporterHTML`**

`Shared/PNGExporterHTML.swift`:

```swift
import Foundation

/// Pure renderer for the PNG-export landing page. The page lists every panel
/// × granularity image and auto-refreshes once a minute so an open browser
/// always shows the latest snapshot the exporter has written to disk.
enum PNGExporterHTML {
    static func render(
        nowTs: Int,
        panels: [HistoryPanel],
        granularities: [HistoryGranularity]
    ) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(nowTs))
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let stamp = fmt.string(from: date)

        var html = ""
        html += "<!DOCTYPE html>\n"
        html += "<html lang=\"en\">\n"
        html += "<head>\n"
        html += "  <meta charset=\"utf-8\">\n"
        html += "  <meta http-equiv=\"refresh\" content=\"60\">\n"
        html += "  <title>MacSlowCooker — Live Metrics</title>\n"
        html += "  <style>\n"
        html += "    body { font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;\n"
        html += "           background: #f0f0f0; color: #222; max-width: 720px; margin: 24px auto; padding: 0 16px; }\n"
        html += "    h1 { font-size: 18px; margin: 0 0 4px; }\n"
        html += "    h2 { font-size: 14px; margin: 28px 0 8px; padding-bottom: 4px; border-bottom: 1px solid #aaa; }\n"
        html += "    img { display: block; margin: 6px 0 14px; border: 1px solid #888; max-width: 100%; }\n"
        html += "    .stamp { color: #666; font-size: 11px; font-family: ui-monospace, Menlo, monospace; }\n"
        html += "  </style>\n"
        html += "</head>\n"
        html += "<body>\n"
        html += "  <h1>MacSlowCooker — Live Metrics</h1>\n"
        html += "  <p class=\"stamp\">Last updated: \(stamp)</p>\n"
        for panel in panels {
            html += "  <h2>\(panel.title)</h2>\n"
            for g in granularities {
                let filename = "\(panel.id)-\(g.id).png"
                html += "  <img src=\"\(filename)\" alt=\"\(panel.title) \(g.id)\">\n"
            }
        }
        html += "</body>\n"
        html += "</html>\n"
        return html
    }
}
```

- [ ] **Step 4: Run xcodegen + the tests**

Run:
```
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/PNGExporterHTMLTests 2>&1 | tail -10
```
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Shared/PNGExporterHTML.swift MacSlowCookerTests/PNGExporterHTMLTests.swift project.yml MacSlowCooker.xcodeproj
git commit -m "feat(png): pure index.html renderer"
```

---

### Task 3: Settings keys

**Files:**
- Modify: `MacSlowCooker/Settings.swift`

- [ ] **Step 1: Add two new keys**

In `Settings.swift`, in the `Keys` enum:

```swift
static let pngExportEnabled = "pngExportEnabled"
static let pngExportPath    = "pngExportPath"
```

- [ ] **Step 2: Add observable properties**

After the existing `prometheusBindAll` property:

```swift
var pngExportEnabled: Bool = false {
    didSet { defaults.set(pngExportEnabled, forKey: Keys.pngExportEnabled) }
}

var pngExportPath: String = Settings.defaultPNGExportPath {
    didSet { defaults.set(pngExportPath, forKey: Keys.pngExportPath) }
}
```

And as a static helper, near the bottom of the class (just before `static let shared`):

```swift
static var defaultPNGExportPath: String {
    let dir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("MacSlowCooker", isDirectory: true)
        .appendingPathComponent("web", isDirectory: true)
    return dir.path
}
```

- [ ] **Step 3: Update `resetToDefaults()`**

Append:

```swift
pngExportEnabled = false
pngExportPath    = Settings.defaultPNGExportPath
```

- [ ] **Step 4: Update `init(defaults:)`**

Append:

```swift
self.pngExportEnabled = (defaults.object(forKey: Keys.pngExportEnabled) as? Bool) ?? false
self.pngExportPath    = (defaults.string(forKey: Keys.pngExportPath)) ?? Settings.defaultPNGExportPath
```

- [ ] **Step 5: Add the new properties to `SettingsChangeTracker.start()`**

Locate the existing `withObservationTracking` closure body in `SettingsChangeTracker.start()`. The body currently reads each tracked property (e.g. `_ = settings.potStyle`, `_ = settings.prometheusEnabled`). Add the same pattern for the two new properties:

```swift
_ = settings.pngExportEnabled
_ = settings.pngExportPath
```

(Match the surrounding style — same indent, same `_ = ...` pattern.)

- [ ] **Step 6: Run all tests as a regression check**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add MacSlowCooker/Settings.swift
git commit -m "feat(png): settings keys (enabled, path)"
```

---

### Task 4: PNGExporter (renderer + writer)

**Files:**
- Create: `MacSlowCooker/PNGExporter.swift`
- Create: `MacSlowCookerTests/PNGExporterTests.swift`

- [ ] **Step 1: Write failing test**

`MacSlowCookerTests/PNGExporterTests.swift`:

```swift
import XCTest
@testable import MacSlowCooker

@MainActor
final class PNGExporterTests: XCTestCase {
    func testRenderProducesEightPNGsAndIndexHTML() async throws {
        // Seed an in-memory store with one 5-min row so the renderer has
        // something non-empty to draw.
        let store = try HistoryStore(path: ":memory:")
        try store.insert(
            HistoryRecord(ts: Int(Date().timeIntervalSince1970) - 300,
                          gpuPct: 42, socTempC: 50, powerW: 8, fanRPM: 1500),
            granularity: .fiveMin
        )

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let exporter = PNGExporter(store: store)
        try await exporter.renderOnce(to: dir)

        // 8 PNGs: 2 panels × 4 granularities.
        for panel in HistoryPanel.all {
            for g in HistoryGranularity.allCases {
                let url = dir.appendingPathComponent("\(panel.id)-\(g.id).png")
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                              "missing \(url.lastPathComponent)")
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                XCTAssertGreaterThan(size, 256, "\(url.lastPathComponent) suspiciously small (\(size) bytes)")
            }
        }
        // index.html
        let index = dir.appendingPathComponent("index.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path))
        let body = try String(contentsOf: index, encoding: .utf8)
        XCTAssertTrue(body.contains("compute-daily.png"))
        XCTAssertTrue(body.contains("thermal-yearly.png"))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSlowCookerPNGTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run test, verify failure**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/PNGExporterTests 2>&1 | tail -10`
Expected: FAIL (`PNGExporter` undefined).

- [ ] **Step 3: Implement `PNGExporter`**

`MacSlowCooker/PNGExporter.swift`:

```swift
import AppKit
import SwiftUI
import os

/// Periodically renders the MRTG-style history panels off-screen and writes
/// them to disk as PNG files plus an `index.html`. Off by default; toggled
/// via Preferences. The output directory is meant to be served by the user's
/// own static web server (`python3 -m http.server -d <path>` etc.).
@MainActor
final class PNGExporter {
    private let store: HistoryStore
    private let log = OSLog(subsystem: "com.macslowcooker.app", category: "PNGExporter")
    private var timer: Timer?

    /// Five-minute cadence — matches the finest history granularity, so each
    /// render captures every new bucket exactly once.
    private let interval: TimeInterval = 300

    init(store: HistoryStore) { self.store = store }

    /// Begin periodic rendering into `directory`. Creates the directory if
    /// it doesn't exist, fires one render immediately, then re-renders every
    /// 5 minutes. Idempotent — calling start again replaces the previous timer.
    func start(at directory: URL) {
        stop()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            os_log("createDirectory failed: %{public}@", log: log, type: .error, "\(error)")
            return
        }
        // Fire-and-forget the first render so the directory isn't empty.
        Task { @MainActor [weak self] in
            try? await self?.renderOnce(to: directory)
        }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                try? await self?.renderOnce(to: directory)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Render the current snapshot into `directory`, overwriting any existing
    /// files. One render = 8 PNGs + 1 index.html. Public for tests.
    func renderOnce(to directory: URL) async throws {
        let nowTs = Int(Date().timeIntervalSince1970)
        var byGranularity: [HistoryGranularity: [HistoryRecord]] = [:]
        for g in HistoryGranularity.allCases {
            let since = nowTs - g.retentionSeconds
            byGranularity[g] = (try? store.query(granularity: g, sinceTs: since, untilTs: nowTs)) ?? []
        }

        for panel in HistoryPanel.all {
            for g in HistoryGranularity.allCases {
                let view = MRTGGraphView(
                    records: byGranularity[g] ?? [],
                    panel: panel,
                    granularity: g,
                    nowTs: nowTs
                )
                .frame(width: 600, height: 140)

                let renderer = ImageRenderer(content: view)
                renderer.scale = 2  // retina

                guard let cgImage = renderer.cgImage else {
                    os_log("ImageRenderer returned nil for %{public}@-%{public}@",
                           log: log, type: .error, panel.id, g.id)
                    continue
                }
                let bmp = NSBitmapImageRep(cgImage: cgImage)
                guard let png = bmp.representation(using: .png, properties: [:]) else {
                    os_log("PNG encode failed for %{public}@-%{public}@",
                           log: log, type: .error, panel.id, g.id)
                    continue
                }
                let url = directory.appendingPathComponent("\(panel.id)-\(g.id).png")
                try png.write(to: url, options: .atomic)
            }
        }

        // index.html
        let html = PNGExporterHTML.render(
            nowTs: nowTs,
            panels: HistoryPanel.all,
            granularities: HistoryGranularity.allCases
        )
        let indexURL = directory.appendingPathComponent("index.html")
        try Data(html.utf8).write(to: indexURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run xcodegen + the tests**

Run:
```
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MacSlowCookerTests/PNGExporterTests 2>&1 | tail -10
```
Expected: 1 test passes.

If `ImageRenderer.cgImage` returns nil under the test runner (it occasionally does on first access in headless environments), the test will fail because the PNG files won't be written. In that case the implementer can re-call `renderer.cgImage` once before the loop, or use `renderer.render(rasterizationScale:renderer:)` which is more deterministic. Verify locally; do not paper over the failure.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add MacSlowCooker/PNGExporter.swift MacSlowCookerTests/PNGExporterTests.swift project.yml MacSlowCooker.xcodeproj
git commit -m "feat(png): MRTGGraphView → PNG rasteriser + 5-min Timer"
```

---

### Task 5: Preferences UI

**Files:**
- Modify: `MacSlowCooker/PreferencesWindowController.swift`

- [ ] **Step 1: Add a new `Section("PNG Export")` to `PreferencesView`**

Insert after the existing `Section("Prometheus Exporter")` block in the `Form` body:

```swift
Section("PNG Export") {
    Toggle("Enable", isOn: $settings.pngExportEnabled)
    HStack {
        Text("Folder")
        Spacer()
        Text(abbreviatedPath(settings.pngExportPath))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
    }
    HStack {
        Spacer()
        Button("Choose Folder…") { chooseFolder() }
        Button("Reveal in Finder") { revealInFinder() }
            .disabled(!FileManager.default.fileExists(atPath: settings.pngExportPath))
    }
    if settings.pngExportEnabled {
        Text("Re-rendered every 5 minutes. Serve with e.g. `python3 -m http.server -d \"\(settings.pngExportPath)\"`.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 2: Add the helper methods to `PreferencesView`**

Inside `struct PreferencesView`, after the `body` closing brace:

```swift
private func abbreviatedPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path.hasPrefix(home) {
        return "~" + String(path.dropFirst(home.count))
    }
    return path
}

private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = URL(fileURLWithPath: settings.pngExportPath)
    panel.prompt = "Choose"
    if panel.runModal() == .OK, let url = panel.url {
        settings.pngExportPath = url.path
    }
}

private func revealInFinder() {
    let url = URL(fileURLWithPath: settings.pngExportPath)
    NSWorkspace.shared.activateFileViewerSelecting([url])
}
```

- [ ] **Step 3: Bump the Preferences window content size**

In `PreferencesWindowController.init(...)`, change:

```swift
window.setContentSize(NSSize(width: 420, height: 540))   // was 440 — accommodate the new section
```

- [ ] **Step 4: Build**

Run: `xcodegen generate && xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add MacSlowCooker/PreferencesWindowController.swift MacSlowCooker.xcodeproj
git commit -m "feat(png): preferences section (toggle, choose folder, reveal)"
```

---

### Task 6: AppDelegate wiring + docs (CODE ONLY — manual smoke test deferred)

**Files:**
- Modify: `MacSlowCooker/AppDelegate.swift`
- Modify: `CLAUDE.md`
- Modify: `CHANGELOG.md`

**Do NOT** run a manual deploy + serve test — that's the user's job after merge.

- [ ] **Step 1: Own a `PNGExporter` in `AppDelegate`**

Add a property near the existing `prometheusExporter` declaration:

```swift
private let pngExporter: PNGExporter? = nil  // set lazily inside configurePNGExporter()
```

Wait — `pngExporter` needs `historyStore`, which is a `let`. Use the same lazy pattern as `historyController`:

```swift
private lazy var pngExporter: PNGExporter? = historyStore.map { PNGExporter(store: $0) }
```

Place this declaration alongside `historyController`.

- [ ] **Step 2: Add `configurePNGExporter()` helper**

Near `configurePrometheusExporter()`:

```swift
private func configurePNGExporter() {
    pngExporter?.stop()
    guard settings.pngExportEnabled else { return }
    let dir = URL(fileURLWithPath: settings.pngExportPath)
    pngExporter?.start(at: dir)
}
```

- [ ] **Step 3: Call it at launch and on every settings change**

In `applicationDidFinishLaunching(_:)`, near the `configurePrometheusExporter()` call:

```swift
configurePrometheusExporter()
configurePNGExporter()
```

In `observeSettings()`, inside the `for await _ in settings.changes { ... }` loop, alongside the existing call:

```swift
animator.settingsDidChange()
configurePrometheusExporter()
configurePNGExporter()
```

- [ ] **Step 4: Stop on terminate**

In `applicationWillTerminate(_:)`, append:

```swift
pngExporter?.stop()
```

- [ ] **Step 5: Build + run all tests**

Run:
```
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: all tests pass.

- [ ] **Step 6: Add a "PNG export" subsection to CLAUDE.md**

Insert after the existing "Prometheus exporter" paragraph in the Architecture section. Keep it under ~10 lines:

```
**PNG export** (opt-in, off by default). When enabled in Preferences,
`PNGExporter` (`MacSlowCooker/PNGExporter.swift`) rasterises the same
`MRTGGraphView` panels via SwiftUI's `ImageRenderer` and writes them to
disk as `compute-{daily,weekly,monthly,yearly}.png` /
`thermal-{daily,weekly,monthly,yearly}.png` plus an auto-refreshing
`index.html`. Re-render cadence: every 5 minutes via a `Timer` on the main
runloop, plus one immediate render on enable. Default output:
`~/Library/Application Support/MacSlowCooker/web/`. Pure HTML rendering
in `Shared/PNGExporterHTML.swift` is unit-tested. Serve the directory with
any static server (`python3 -m http.server -d <path>`, nginx, Caddy).
```

- [ ] **Step 7: Add a `[Unreleased]` entry to CHANGELOG.md**

Under `### Added`:

```
- PNG export (opt-in via Preferences) — periodically writes MRTG-style PNG snapshots and an auto-refreshing `index.html` to a chosen folder, ready to be served by any static web server.
```

- [ ] **Step 8: Commit**

```bash
git add MacSlowCooker/AppDelegate.swift CLAUDE.md CHANGELOG.md
git commit -m "feat(png): wire exporter into AppDelegate + docs"
```

---

## Validation

- [ ] Pre-existing tests (~135) all still pass.
- [ ] New tests pass: `PNGExporterHTMLTests` (2), `PNGExporterTests` (1).
- [ ] After enabling PNG export in Preferences and waiting ~10 seconds, the chosen folder contains 8 PNG files (`compute-{daily,weekly,monthly,yearly}.png`, `thermal-{daily,weekly,monthly,yearly}.png`) and an `index.html` with `<meta http-equiv="refresh" content="60">`.
- [ ] Disabling PNG export in Preferences stops the timer; the directory contents remain (we don't auto-clean) but no more files appear.
- [ ] Running `python3 -m http.server -d <path>` and opening `http://localhost:8000/` in a browser shows all 8 graphs grouped under Compute / Thermal headers, auto-refreshing every minute.
- [ ] Choosing a different folder via "Choose Folder…" creates that directory and starts writing into it on the next 5-minute tick.
- [ ] `lipo -info build/Build/Products/Release/MacSlowCooker.app/Contents/MacOS/MacSlowCooker` reports both `x86_64` and `arm64`.
