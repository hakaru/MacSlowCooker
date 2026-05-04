# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

MacSlowCooker is a macOS desktop app that surfaces GPU usage, SoC temperature,
power, and fan RPM through a Dock icon and a popup window. It talks over XPC
to a `powermetrics` LaunchDaemon that runs as root, and ships as a Universal
Binary (arm64 + x86_64) so the same `.app` runs natively on Apple Silicon and
Intel Macs.

## Development commands

```bash
# Swap the Apple Developer Team ID across the 5 places that pin it
# (Shared/CodeSigningConfig.swift, HelperTool/Info.plist, project.yml,
# README.md, this file). Required after forking with a different cert.
bin/set-team-id.sh ABC1234XYZ

# Regenerate the Xcode project (after editing project.yml or adding files)
xcodegen generate

# Signed Release build (signing is required for the helper to load)
xcodebuild -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -configuration Release \
  -derivedDataPath build build \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=K38MBRNKAT \
  ONLY_ACTIVE_ARCH=NO

# Tests (CODE_SIGNING_ALLOWED=NO skips code signing)
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# Single test
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/PowerMetricsParserTests/testParseFullTahoeSample
```

`ONLY_ACTIVE_ARCH=NO` is what produces a true Universal Binary; without it
xcodebuild emits only the host arch slice. CI (`.github/workflows/ci.yml`)
runs the same build + test pipeline on every PR into `main`.

## Deploy

`/Applications/MacSlowCooker.app` tends to end up root-owned after the first
deploy. Take ownership once and subsequent swaps don't need sudo:

```bash
sudo chown -R $(whoami):staff /Applications/MacSlowCooker.app
```

Then the deploy cycle is:

```bash
pkill -9 -x MacSlowCooker
ditto build/Build/Products/Release/MacSlowCooker.app /Applications/MacSlowCooker.app
open /Applications/MacSlowCooker.app
```

**The HelperTool keeps running under launchd, so any change to helper code
requires restarting it explicitly:**

```bash
sudo launchctl kickstart -k system/com.macslowcooker.helper
```

Skip this and the new binary in `/Applications` is dead weight — the old
process keeps serving XPC and you'll chase phantom bugs that "shouldn't be
there anymore." `HelperInstaller.refreshIfStale` will eventually self-heal
when CFBundleVersion bumps, but during active development the manual
kickstart is faster.

## Architecture

```
MacSlowCooker.app (unprivileged, runs in the user login session)
  ├── main.swift                  — sets AppDelegate on NSApplication.shared
  ├── AppDelegate                 — XPC connection, settings observation,
  │                                 menus, sleep notifications
  ├── GPUDataStore                — @Observable ring buffer (60 samples)
  ├── Settings                    — @Observable + UserDefaults + AsyncStream<Void>
  ├── XPCClient                   — NSXPCConnection (.privileged), exponential
  │                                 backoff reconnect, 2 Hz polling
  ├── HelperInstaller             — SMAppService.daemon registration + auto
  │                                 re-register on stale helper binary
  ├── DockIconAnimator            — Timer-driven state machine
  │                                 (interpolation / wiggle / boiling fade)
  ├── DutchOvenRenderer           — Core Graphics drawing of pot, flame, steam
  │                                 (conforms to PotRenderer)
  ├── PopupView                   — SwiftUI dashboard (4 charts + 4 metrics)
  ├── PopupWindowController       — NSWindow (titled / closable / resizable,
  │                                 .floating toggleable)
  └── PreferencesWindowController — NSWindow + SwiftUI Form

HelperTool (root LaunchDaemon, Contents/MacOS/HelperTool)
  ├── main.swift                  — NSXPCListener + HelperService.shared;
  │                                 mutable state isolated by `actor HelperState`
  ├── PowerMetricsRunner          — keeps /usr/bin/powermetrics running and
  │                                 parses its NUL-separated plist stream
  ├── IOAcceleratorReader         — IOAccelerator → "Device Utilization %"
  │                                 (matches Activity Monitor)
  ├── SMCReader                   — direct AppleSMC user-client; reads FNum +
  │                                 F[i]Ac fan keys (fpe2 / flt formats)
  └── TemperatureReader           — IOHIDEventSystem-based SoC temperature

Shared (compiled into both targets)
  ├── DomainTypes                 — PotStyle / FlameAnimation /
  │                                 BoilingTrigger / IconState / ThermalPressure
  ├── GPUSample                   — Codable data model
  ├── XPCProtocol                 — MacSlowCookerHelperProtocol
  ├── PowerMetricsParser          — pure / testable plist parser
  ├── PlistStreamSplitter         — pure NUL-separated buffer splitter
  ├── SMCFanDecoder               — pure fpe2 / flt fan-RPM decoder
  ├── IOAcceleratorSelection      — pure max-aggregation across services
  ├── SensorNameMatcher           — pure die / gpu / proximity / graphics name match
  ├── CookingHeuristics           — pure boiling/temperature rules used by animator
  ├── HostCPU                     — runtime Apple Silicon detection
  └── CodeSigningConfig           — single source for Team OU + XPC requirement
```

**Pure-helper pattern**. The IOKit-bound classes (`SMCReader`,
`IOAcceleratorReader`, `TemperatureReader`, `PowerMetricsRunner`) are thin
wrappers over the IOKit / Process APIs. The byte-level / sort / match /
buffer logic each lifts into a pure type in `Shared/` (`SMCFanDecoder`,
`IOAcceleratorSelection`, `SensorNameMatcher`, `PlistStreamSplitter`,
`PowerMetricsParser`). Tests exercise the pure types directly without
needing a live SMC connection or spawned process — when adding a new
reader, follow the same split.

Sample-acquisition flow:
1. `HelperService` calls `PowerMetricsRunner.start()` at first XPC connection,
   which spawns `/usr/bin/powermetrics` (Apple Silicon: `--samplers
   gpu_power,ane_power,thermal --show-all`; Intel: `--samplers
   gpu_power,thermal`).
2. `PlistStreamSplitter` chops the NUL-separated stream; `PowerMetricsParser`
   parses each plist; `TemperatureReader` augments with SoC temp; the result
   is JSON-encoded.
3. `XPCClient` polls `fetchLatestSample` at 2 Hz (every 0.5 s), feeds the
   sample into `GPUDataStore`, and re-renders the Dock icon.
4. To avoid the "--" placeholder on cold launch, `startSampling` synthesizes
   an IOKit-only primer sample (GPU% / temp / fan, no power) and stores it
   immediately so the popup fills in within the first poll instead of
   waiting ~1.3 s for powermetrics' first emission.

**History subsystem**. Long-term trends are stored in a round-robin SQLite database
(`~/Library/Application Support/MacSlowCooker/history.sqlite`) with four granularity
tiers: 5-min/24h, 30-min/7d, 2-hour/31d, 1-day/400d. `HistoryIngestor` (Main-Actor)
buffers incoming samples in-memory for 5 minutes, then rolls them up via `HistoryAggregator`
(pure) into the four tables on a staggered schedule — new samples only hit the app,
not the helper. `HistoryStore` manages insert, query, and cascading rollup. `HistoryView`
renders MRTG-style 4-panel Daily / Weekly / Monthly / Yearly graphs for GPU / Temp / Power / Fan,
wired to a window accessible via Cmd+Shift+H from the app menu.

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

## macOS 26 (Tahoe) gotchas

**powermetrics output schema changed**. The capitalized keys that worked up
through macOS 14 (`GPU.gpu_active_residency`, `gpu_power_mW`,
`gpu_die_temperature`) are **completely absent on macOS 26**. The new shape:
- GPU usage: `dict["gpu"]["idle_ratio"]` → `1 - idle_ratio`
- GPU power: `dict["gpu"]["gpu_energy"]` (mJ) divided by `dict["elapsed_ns"]` → W
- ANE power: `dict["processor"]["ane_power"]` (mW), surfaces only when
  `--show-all` is passed
- GPU temperature: not exposed; only the categorical
  `thermal_pressure: "Nominal"` / "Fair" / "Serious" / "Critical" remains

`PowerMetricsParser` tries the legacy keys first and falls back to the new
ones, so a single binary handles both schemas.

**The `smc` sampler was removed in macOS 26**. `powermetrics --help` lists
only `tasks/battery/network/disk/interrupts/cpu_power/thermal/sfi/gpu_power/
ane_power`. Passing `--samplers smc` crashes powermetrics on launch, which
trips `PowerMetricsRunner.handleCrash()`'s exponential backoff three times
and surfaces "GPU monitoring unavailable" in the error UI. We read fan RPM
directly from SMC instead.

**Fan RPM acquisition**. `HelperTool/SMCReader.swift` opens an AppleSMC user
client via `IOServiceMatching("AppleSMC")` and calls
`IOConnectCallStructMethod(connection, kSMCHandleYPCEvent=2, ...)` to read
`FNum` (UInt8 fan count) and `F[i]Ac` (fpe2: 16-bit big-endian, 14 integer +
2 fractional bits, RPM = raw / 4.0). Mac Studio (Mac15,14, M3 Ultra) reports
2 fans. The helper runs as root, so `IOServiceOpen` against AppleSMC always
succeeds.

**Temperature sensors**. There is no "GPU MTR Temp Sensor" entry in
IOHIDEventSystem on Apple Silicon. The M3 Ultra exposes only `PMU tdie*` /
`PMU tdev*` (77 of them). Intel Macs surface heat as `GPU Proximity` or
`Graphics Processor Die *`. `TemperatureReader` accepts any sensor whose
Product name contains `die`, `tdev`, `gpu`, `proximity`, or `graphics`, then
averages — that's why the popup label says "SoC temp" on Apple Silicon and
plain "Temp" otherwise. A truly GPU-specific reading would require SMC
`Tg05` / `Tg0D` and is not implemented yet.

**Fanless Macs (e.g. MacBook Air M-series)**. AppleSMC has no `FNum` key on
fanless hardware, so `SMCReader` logs `SMC: FNum read failed` once at
init — this is expected, not an error. `GPUSample.fanRPM` then arrives as
nil, which both the renderer and the popup treat as the fanless signal:
- `DutchOvenRenderer.steamIntensity(state:)` falls back to a
  `(temp - 50) / 45` ramp (same 50 °C → 95 °C range as `potColor`), so
  pot color and steam liveliness move together. Fan-equipped Macs keep
  the `(rpm - 1300) / 2200` clamp.
- `PopupView.hasFans` (`latest?.fanRPM != nil`) gates the Fan chart and
  Fan metric tile out of the layout, leaving a 3-column GPU /
  Temperature / Power view.

**Intel powermetrics keys**. Intel powermetrics emits
`gpu.gpu_busy` (integer percent) or `gpu.busy_ns` + `(gpu|root).elapsed_ns`,
not `gpu_active_residency` / `idle_ratio`. The parser tries each in turn.

**The `@main` AppDelegate trap**. On macOS 26, decorating an
`NSApplicationDelegate`-conforming class with `@main` does not actually wire
`NSApp.delegate`, and `applicationDidFinishLaunching` never fires.
`MacSlowCooker/main.swift` sets the delegate explicitly:

```swift
MainActor.assumeIsolated {
    NSApplication.shared.delegate = AppDelegate()
    NSApplication.shared.run()
}
```

**HelperTool Info.plist embedding**. A `type: tool` (CLI) target normally
doesn't embed `Info.plist`, so codesign reports `Info.plist=not bound` and
`SMAppService.daemon` refuses to register. Fix in `project.yml`:

```yaml
OTHER_LDFLAGS: "-sectcreate __TEXT __info_plist $(INFOPLIST_FILE)"
```

`-sectcreate` does not expand build variables, so `HelperTool/Info.plist`'s
`CFBundleIdentifier` is hardcoded to `com.macslowcooker.helper` rather than
referencing `$(PRODUCT_BUNDLE_IDENTIFIER)`.

**HelperTool placement**. The binary lives at `Contents/MacOS/HelperTool` and
the plist at `Contents/Library/LaunchDaemons/com.macslowcooker.helper.plist`,
with the plist's `BundleProgram` pointing back at `Contents/MacOS/HelperTool`.
Putting the binary inside `Contents/Library/LaunchDaemons/` makes
`SMAppService.daemon.status` return `.notFound`.

**XPC connection options**. Mach services exposed by a LaunchDaemon require
`NSXPCConnection(machServiceName:options:)` with **`.privileged`**.

**Dock-icon visibility**. `LSUIElement = true` in `Info.plist` hides the
Dock icon, as does `setActivationPolicy(.accessory)` in `AppDelegate`. We
remove both and run as `.regular` so the Dock icon appears (clicking it
calls `applicationShouldHandleReopen`).

**`SMAuthorizedClients` requirement string**. A loose requirement
(`identifier "com.macslowcooker.app" and anchor apple generic` alone) is
sometimes rejected. Always include the Team OU:

```
identifier "com.macslowcooker.app" and anchor apple generic and certificate leaf[subject.OU] = "K38MBRNKAT"
```

## HelperTool security

Incoming XPC connections are validated with `setCodeSigningRequirement` (a
public macOS 13+ API). `shouldAcceptNewConnection` sets the requirement on
the connection and macOS performs the signature check:

```swift
connection.setCodeSigningRequirement(CodeSigningConfig.xpcClientRequirement)
```

`CodeSigningConfig` (in `Shared/`) holds the Team OU and bundle id and
constructs the requirement string at runtime, so there's only one place to
edit when forking. `bin/set-team-id.sh` updates every place that references
the Team ID in lockstep (the constant, plist, project.yml, README, this
file).

**`HelperService` is a singleton (`HelperService.shared`)**. The XPC
listener delegate hands `HelperService.shared` to every connection so they
all share one powermetrics process. Returning a fresh instance per
connection would spin up duplicate powermetrics children.

`sampling` and `latestSampleData` live inside a private
`actor HelperState`. Every mutation hops via `Task { await state.foo() }`,
which is cleaner than the old serial-DispatchQueue design and survives
Swift 6 strict-concurrency.

`PowerMetricsRunner.stop()` sets `isStopping = true` before calling
`terminate()`. The terminationHandler runs but observes the flag and skips
the crash-handling restart path.

## SourceKit false positives

Shared types (`GPUSample`, `MacSlowCookerHelperProtocol`, `GPUDataStore`,
etc.) sometimes show up as "not in scope" in the editor. Indexing artifact
— `xcodebuild` builds and tests cleanly. After adding new Swift files run
`xcodegen generate` and restart Xcode to refresh the index.

## Debugging cookbook

- The app launches but does nothing → run it directly to see stderr:
  ```bash
  /Applications/MacSlowCooker.app/Contents/MacOS/MacSlowCooker
  ```
- Helper status:
  ```bash
  launchctl print system/com.macslowcooker.helper | head -30
  ```
- Capture raw powermetrics plist data: temporarily add code in
  `PowerMetricsRunner.flushSamplesLocked` that writes the chunk to `/tmp`
  before parsing — essential when the macOS schema doesn't match
  expectations.

## Intel Mac support

The Universal Binary is enabled by `ARCHS: "arm64 x86_64"` in `project.yml`.
Sampler choice keys off the **host CPU at runtime** via
`HostCPU.isAppleSilicon` (which reads `sysctlbyname("hw.optional.arm64")`),
not compile-time `#if arch(...)`. That way a Universal Binary's x86_64
slice running under Rosetta on an Apple Silicon host still asks for
`ane_power` because the kernel still exposes the ANE.

- **powermetrics samplers**: Intel drops `ane_power` (no Apple Neural
  Engine) and the `--show-all` flag (which only exists for ANE on macOS 26).
- **Parser**: `gpuUsage` stays `Double` (non-Optional); Intel-specific
  `gpu_busy` and `busy_ns / elapsed_ns` keys feed the same field via
  `PowerMetricsParser`'s coalesce/fallback chain.
- **TemperatureReader**: `SensorNameMatcher` accepts the Intel-style
  `proximity` and `graphics` sensor names alongside Apple Silicon's
  `die` / `tdev` / `gpu`.
- **PopupView**: layout is shared between Apple Silicon and Intel. ANE
  power is not surfaced in any metric tile, so it just stays nil on Intel.

**Real Intel powermetrics keys are vendor-specific** — AMD Radeon, Intel
integrated, etc. all emit slightly different shapes by macOS version. On
first deploy to a new Intel machine, dump a chunk to `/tmp` (see "Debugging
cookbook" above) and adjust `PowerMetricsParser` keys if the popup stays
empty.

## Environment

- macOS 14 Sonoma or later. **macOS 26 (Tahoe) changed the powermetrics
  output schema substantially** — see the gotchas section above.
- Universal Binary covers Apple Silicon (M1–M4) and Intel Macs. Fanless
  Macs (MacBook Air M-series) are first-class — see the gotchas section.
- Automatic code signing, Team `K38MBRNKAT` (override via
  `bin/set-team-id.sh <YOUR_TEAM_ID>` when forking).
- Contributor-facing setup notes live in `CONTRIBUTING.md`; this file
  focuses on operational / architectural context for code agents.
