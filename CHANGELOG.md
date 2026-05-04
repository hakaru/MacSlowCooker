# Changelog

All notable changes are tracked here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- **Fanless Mac support**: `DutchOvenRenderer.steamIntensity` (renamed from
  `fanIntensity`) falls back to a temperature ramp (50 °C → 95 °C) when
  `fanRPM == nil`, so the steam still tracks pot heat on MacBook Air-class
  hardware. Fan-equipped Macs keep the previous `(rpm - 1300) / 2200` curve.
  `PopupView` hides the Fan chart and Fan metric tile when no fans are
  reported (3-column layout instead of 4).

### Added
- **Prometheus exporter** (opt-in via Preferences) — exposes live GPU/temp/power/fan/thermal/helper metrics on `http://127.0.0.1:9091/metrics` for Prometheus, Grafana Agent, and other compatible scrapers.
- **History window**: MRTG-style Daily / Weekly / Monthly / Yearly graphs for
  GPU / Temp / Power / Fan, accessible via Cmd+Shift+H.
- **Local round-robin SQLite store**: `~/Library/Application Support/MacSlowCooker/history.sqlite`
  with 24h/7d/31d/400d retention across four granularity tiers (5-min / 30-min / 2-hour / 1-day).
- **3D drum-shape pot icon**: cylindrical body with elliptical top rim and
  base, dome lid with knob, back rim drawn behind the lid, and chunky loop
  handles — replaces the earlier flat-rectangle silhouette
- **Layered flame**: asymmetric three-layer bezier teardrop (red-orange /
  orange / yellow-white core) with a curling tip and a soft radial halo
- **Soft puff steam**: stacks of overlapping radial-gradient puffs that grow
  with fan RPM and fade as they rise — replaces the stroked wavy lines
- **Brighter background**: 3-stop blue gradient (sky → mid → anchor) replacing
  the previous flatter 2-stop
- **Universal Binary** (arm64 + x86_64) for Apple Silicon and Intel
- **Intel powermetrics support**: parser recognizes Intel keys (`gpu_busy`,
  `busy_ns` + `elapsed_ns`); helper omits `ane_power` sampler on Intel;
  TemperatureReader matches Intel-style `proximity` / `graphics` sensors
- **Helper version sync**: `HelperInstaller.refreshIfStale` queries the running
  helper's CFBundleVersion via XPC and re-registers the daemon if it differs
  from the bundled binary, so stale helpers no longer survive a deploy
- **Cold-launch primer sample**: `HelperService.startSampling` synthesizes an
  IOKit-only first sample (GPU% / temp / fan, no power) so the popup fills
  within hundreds of milliseconds instead of waiting 2–3 s for powermetrics'
  first plist
- **2 Hz polling** (was 1 Hz) plus an immediate fetch on connect
- **HelperService Actor isolation**: mutable state moved into a private
  `actor HelperState`, eliminating the data-race risk that strict-concurrency
  mode would flag on the previous queue-based design
- **Deterministic IOAccelerator service selection**: services are sorted by
  IORegistry name and the first one with a usable percentage wins; all
  detected services are logged on first read for diagnosis
- **SMCKeyData stride guard**: `SMCReader.init?()` checks
  `MemoryLayout<SMCKeyData>.stride == 80` and refuses to open SMC on drift,
  so layout regressions surface as graceful nil instead of garbled reads
- **Window-level preference**: a "Float above other windows" toggle in
  Preferences (default ON), applied immediately via Settings.changes
- **Low Power Mode honor**: animator drops to 5 fps and disables flame wiggle
  while LPM is on; Preferences shows a live status row explaining the override
- **Popup chart nil handling**: nil temperature / fan / power samples render
  as gaps in the chart instead of misleading flat-zero baselines
- **macOS 26 (Tahoe) parser tests**: synthetic plist fixtures cover
  `gpu.idle_ratio`, `gpu.gpu_energy + elapsed_ns`, `processor.ane_power`, and
  `thermal_pressure`

### Architecture (PoC foundation)
- `PotRenderer` protocol so pot styles can be swapped (Phase 2 will add
  oden, curry, etc.)
- `DockIconAnimator` Timer-based state machine
  - exponential lerp for smooth height interpolation (0.7 s time constant)
  - sine-based wiggle phase for flame motion
  - 5 s sustained `aboveThresholdSince` triggers the boiling animation
  - Timer auto-stops when no animation is in flight → idle CPU 0%
  - `IconState.visualHash` skips redundant Dock-icon updates (cuts WindowServer
    IPC chatter)
  - subscribes to `NSWorkspace` sleep notifications
- `Settings` is `@Observable`-based with `UserDefaults` persistence and a
  `Settings.changes: AsyncStream<Void>` for downstream observers
- `Clock` protocol + `TestClock` makes time-dependent logic deterministic in
  tests

### Tests
- 53 unit tests, all passing
- Snapshot (PNG match) tests are intentionally out of scope for the PoC

### Fixed
- `SMAppService.notFound` false positive: `register()` is attempted anyway
- Legacy `GPUSampleTests` / `GPUDataStoreTests` updated for the new
  `thermalPressure` and `anePower` fields
- `XCTestConfigurationFilePath` env var causes `AppDelegate` to skip helper
  setup under XCTest (avoids modal NSAlert blocking the test runner)
- Pot icon flame was clipped behind the body in early iterations — pot Y
  range now sits at 36–64 % so the flame stays visible

### Documentation
- Apache License 2.0 added (`LICENSE`, `NOTICE`)
- Design spec: `docs/superpowers/specs/2026-05-03-pot-icon-poc-design.md`
- Implementation plan: `docs/superpowers/plans/2026-05-03-pot-icon-poc-implementation.md`
- macOS 26 platform gotchas consolidated into `CLAUDE.md`

### Phase 2 backlog (closed)
- #1 CGLayer caching of static parts — closed as deferred-until-measured
- #2 Honor Low Power Mode — implemented
- #3 SMCKeyData layout guard — implemented
- #4 HelperService Actor migration — implemented
- #5 powermetrics → IOReport migration — partial (primer sample reduces the
  fields that depend on powermetrics); full IOReport bindings remain a
  separate task
- #6 Helper version sync on binary change — implemented
- #7 macOS 26 powermetrics plist fixture tests — implemented
- #8 Don't plot nil samples as zero — implemented
- #9 Window level / floating preference — implemented
- #10 IOAcceleratorReader narrow service matching — implemented (deterministic
  selection + first-read logging)
- #11 First-sample latency on launch — implemented (primer + 2 Hz polling)

## [Pre-PoC] — 2026-05-02

### Added (foundation work, before the pot-icon-poc branch)
- Initial Xcode project scaffold (xcodegen)
- Vertical-bar Dock icon (`DockIconRenderer`, removed in the PoC)
- HelperTool / XPC plumbing (`MacSlowCookerHelperProtocol`)
- `PowerMetricsRunner` for the long-running powermetrics process
- `TemperatureReader` for SoC temperature via IOHIDEventSystem
- `GPUDataStore` 60-element ring buffer
- Initial popup UI (NSPanel)

### Renamed
- Project-wide: GPUSMI → MacSlowCooker (bundle id, plist Label, directory
  names, helper keys)

### Fixed
- macOS 26 compatibility
  - `@main` trap: `AppDelegate` is set explicitly in `main.swift`
  - Removed `LSUIElement` so the Dock icon shows
  - HelperTool Info.plist embedding (`-sectcreate` flag)
  - SMAppService designated requirement now includes the Team OU
  - powermetrics new schema (`idle_ratio`, `gpu_energy`)
- IOHID GPU temperature crash worked around by temporarily disabling
  `readGPUTemperature()`
