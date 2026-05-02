# Pot Icon PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bar-style Dock icon with a Dutch-oven + flame visualization, with configurable animation and boiling triggers via a Preferences window.

**Architecture:** Pluggable `PotRenderer` protocol + `DockIconAnimator` state machine (Timer-driven) + `@Observable Settings` store + SwiftUI Preferences window. PoC implements `DutchOvenRenderer`; future styles drop in by conforming to `PotRenderer`. `Clock` abstraction makes time-dependent logic deterministically testable.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI (Preferences only), Core Graphics (rendering), XCTest, UserDefaults, Observation framework, NSWorkspace notifications.

**Source spec:** `docs/superpowers/specs/2026-05-03-pot-icon-poc-design.md`.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `MacSlowCooker/PotRenderer.swift` | NEW | `PotStyle`/`FlameAnimation`/`BoilingTrigger` enums, `IconState` struct (with `visualHash`), `PotRenderer` protocol |
| `MacSlowCooker/Clock.swift` | NEW | `Clock` protocol + `SystemClock` |
| `MacSlowCooker/Settings.swift` | NEW | `@Observable Settings` + `UserDefaults` persistence + `changes` `AsyncStream` |
| `MacSlowCooker/DutchOvenRenderer.swift` | NEW | Dutch-oven CG drawing |
| `MacSlowCooker/DockIconAnimator.swift` | NEW | Animator state machine + Timer + `computeBoiling` static helper |
| `MacSlowCooker/PreferencesWindowController.swift` | NEW | `NSWindow` + SwiftUI `PreferencesView` |
| `MacSlowCooker/AppDelegate.swift` | MODIFIED | Wire animator/settings/menu/sleep notifications, replace `updateDockIcon` |
| `MacSlowCookerTests/TestClock.swift` | NEW | Mutable Clock test helper |
| `MacSlowCookerTests/SettingsTests.swift` | NEW | Defaults, persistence, fallback, changes stream |
| `MacSlowCookerTests/BoilingTriggerTests.swift` | NEW | Table-form parameterized tests of `computeBoiling` |
| `MacSlowCookerTests/DockIconAnimatorTests.swift` | NEW | Interpolation/wiggle/boiling/timer-lifecycle/sleep/dedup tests |
| `MacSlowCookerTests/DutchOvenRendererTests.swift` | NEW | Smoke tests (non-empty image, no-crash range) |
| `MacSlowCooker/DockIconRenderer.swift` | DELETED | Replaced by `DutchOvenRenderer` |
| `MacSlowCookerTests/DockIconRendererTests.swift` | DELETED | Replaced |

`project.yml` uses recursive globbing for `MacSlowCooker/` and `MacSlowCookerTests/`, so new files are auto-picked. Run `xcodegen generate` after adding files.

---

## Task 1: Foundation types — `PotRenderer.swift`

**Files:**
- Create: `MacSlowCooker/PotRenderer.swift`

This task only declares types — no production logic, no tests. It exists so later tasks can reference these symbols without forward dependencies.

- [ ] **Step 1: Create the file with all foundation types**

Write `MacSlowCooker/PotRenderer.swift`:

```swift
import AppKit
import Foundation

// MARK: - Settings enums

enum PotStyle: String, CaseIterable, Codable {
    case dutchOven = "dutchOven"
    // 将来: case oden, curry, saucepan
}

enum FlameAnimation: String, CaseIterable, Codable {
    case none           = "none"
    case interpolation  = "interpolation"
    case wiggle         = "wiggle"
    case both           = "both"

    var hasInterpolation: Bool { self == .interpolation || self == .both }
    var hasWiggle: Bool        { self == .wiggle        || self == .both }
}

enum BoilingTrigger: String, CaseIterable, Codable {
    case temperature       = "temperature"
    case thermalPressure   = "thermalPressure"
    case combined          = "combined"
}

// MARK: - Renderer input

struct IconState: Equatable {
    let displayedUsage: Double      // [0, 1] interpolated value
    let temperature: Double?        // °C, nil if unavailable
    let isConnected: Bool

    let flameWigglePhase: Double    // [0, 2π) — ignored when wiggle disabled
    let flameWiggleEnabled: Bool

    let isBoiling: Bool
    let boilingIntensity: Double    // [0, 1] faded value
}

extension IconState {
    /// Quantized hash used to skip redundant Dock icon updates.
    /// Two states with the same `visualHash` produce visually indistinguishable bitmaps.
    var visualHash: Int {
        var hasher = Hasher()
        hasher.combine(isConnected)
        hasher.combine(flameWiggleEnabled)
        hasher.combine(isBoiling)
        hasher.combine(Int((displayedUsage * 200.0).rounded()))    // 0.005 step
        hasher.combine(Int((boilingIntensity * 100.0).rounded())) // 0.01 step
        if flameWiggleEnabled {
            hasher.combine(Int((flameWigglePhase * 20.0).rounded())) // 0.05 rad step
        }
        return hasher.finalize()
    }
}

// MARK: - Renderer protocol

protocol PotRenderer {
    static var iconSize: CGSize { get }
    static func render(state: IconState) -> NSImage
}

extension PotRenderer {
    static var iconSize: CGSize { CGSize(width: 512, height: 512) }
}
```

- [ ] **Step 2: Regenerate Xcode project and verify build**

Run:
```bash
xcodegen generate
xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: build succeeds. (`DockIconRenderer.swift` is still present and builds; we delete it later.)

- [ ] **Step 3: Commit**

```bash
git add MacSlowCooker/PotRenderer.swift MacSlowCooker.xcodeproj
git commit -m "feat: add PotRenderer protocol and IconState foundation types"
```

---

## Task 2: Clock abstraction

**Files:**
- Create: `MacSlowCooker/Clock.swift`
- Create: `MacSlowCookerTests/TestClock.swift`

`Clock` lets the animator's time-dependent logic (5-second persistence in `.combined` mode, fade timing) be tested deterministically.

- [ ] **Step 1: Create production Clock**

Write `MacSlowCooker/Clock.swift`:

```swift
import Foundation

protocol Clock: AnyObject {
    var now: Date { get }
}

final class SystemClock: Clock {
    var now: Date { Date() }
}
```

- [ ] **Step 2: Create test helper**

Write `MacSlowCookerTests/TestClock.swift`:

```swift
import Foundation
@testable import MacSlowCooker

/// Mutable Clock used by DockIconAnimator tests. Time only moves when `advance(by:)` is called.
final class TestClock: Clock {
    private(set) var now: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.now = start
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
```

- [ ] **Step 3: Regenerate and build**

```bash
xcodegen generate
xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add MacSlowCooker/Clock.swift MacSlowCookerTests/TestClock.swift MacSlowCooker.xcodeproj
git commit -m "feat: add Clock protocol with SystemClock and TestClock"
```

---

## Task 3: Settings storage with persistence

**Files:**
- Create: `MacSlowCooker/Settings.swift`
- Create: `MacSlowCookerTests/SettingsTests.swift`

`Settings` is `@Observable` so SwiftUI views auto-update and the animator can subscribe to changes. Persistence via `UserDefaults`. Tests use a custom `UserDefaults` suite to avoid polluting global defaults.

- [ ] **Step 1: Write failing tests**

Write `MacSlowCookerTests/SettingsTests.swift`:

```swift
import XCTest
@testable import MacSlowCooker

@MainActor
final class SettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "com.macslowcooker.tests.settings"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func testDefaultValues() {
        let s = Settings(defaults: defaults)
        XCTAssertEqual(s.potStyle, .dutchOven)
        XCTAssertEqual(s.flameAnimation, .both)
        XCTAssertEqual(s.boilingTrigger, .combined)
    }

    func testPersistsChanges() {
        let s1 = Settings(defaults: defaults)
        s1.flameAnimation = .wiggle
        s1.boilingTrigger = .temperature

        let s2 = Settings(defaults: defaults)
        XCTAssertEqual(s2.flameAnimation, .wiggle)
        XCTAssertEqual(s2.boilingTrigger, .temperature)
    }

    func testFallsBackOnInvalidRawValue() {
        defaults.set("nonsense", forKey: "flameAnimation")
        defaults.set("",         forKey: "boilingTrigger")

        let s = Settings(defaults: defaults)
        XCTAssertEqual(s.flameAnimation, .both)
        XCTAssertEqual(s.boilingTrigger, .combined)
    }

    func testEachSetterPersists() {
        let s = Settings(defaults: defaults)
        s.potStyle = .dutchOven
        s.flameAnimation = .interpolation
        s.boilingTrigger = .thermalPressure

        XCTAssertEqual(defaults.string(forKey: "potStyle"),       "dutchOven")
        XCTAssertEqual(defaults.string(forKey: "flameAnimation"), "interpolation")
        XCTAssertEqual(defaults.string(forKey: "boilingTrigger"), "thermalPressure")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/SettingsTests
```
Expected: FAIL (compile error: `Settings` undefined).

- [ ] **Step 3: Write the minimal implementation**

Write `MacSlowCooker/Settings.swift`:

```swift
import Foundation
import Observation

@Observable
@MainActor
final class Settings {

    enum Keys {
        static let potStyle       = "potStyle"
        static let flameAnimation = "flameAnimation"
        static let boilingTrigger = "boilingTrigger"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    var potStyle: PotStyle = .dutchOven {
        didSet { defaults.set(potStyle.rawValue, forKey: Keys.potStyle) }
    }

    var flameAnimation: FlameAnimation = .both {
        didSet { defaults.set(flameAnimation.rawValue, forKey: Keys.flameAnimation) }
    }

    var boilingTrigger: BoilingTrigger = .combined {
        didSet { defaults.set(boilingTrigger.rawValue, forKey: Keys.boilingTrigger) }
    }

    static let shared = Settings()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.potStyle       = PotStyle(rawValue: defaults.string(forKey: Keys.potStyle) ?? "")        ?? .dutchOven
        self.flameAnimation = FlameAnimation(rawValue: defaults.string(forKey: Keys.flameAnimation) ?? "") ?? .both
        self.boilingTrigger = BoilingTrigger(rawValue: defaults.string(forKey: Keys.boilingTrigger) ?? "") ?? .combined
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/SettingsTests
```
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add MacSlowCooker/Settings.swift MacSlowCookerTests/SettingsTests.swift MacSlowCooker.xcodeproj
git commit -m "feat: add @Observable Settings with UserDefaults persistence"
```

---

## Task 4: Settings change-stream

**Files:**
- Modify: `MacSlowCooker/Settings.swift`
- Modify: `MacSlowCookerTests/SettingsTests.swift`

Adds an `AsyncStream<Void>` that yields once per mutation. Used by `AppDelegate` to call `animator.settingsDidChange()`.

- [ ] **Step 1: Add failing test**

Append to `MacSlowCookerTests/SettingsTests.swift` (inside the class):

```swift
    func testChangesStreamYieldsOnEachMutation() async {
        let s = Settings(defaults: defaults)

        // Settings is @MainActor — Task body must be too.
        let task = Task<Int, Never> { @MainActor [s] in
            var count = 0
            for await _ in s.changes {
                count += 1
                if count == 2 { break }
            }
            return count
        }

        // Give the tracker time to arm
        try? await Task.sleep(nanoseconds: 50_000_000)

        s.flameAnimation = .wiggle
        try? await Task.sleep(nanoseconds: 20_000_000)
        s.boilingTrigger = .temperature

        let count = await task.value
        XCTAssertEqual(count, 2)
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/SettingsTests/testChangesStreamYieldsOnEachMutation
```
Expected: FAIL (compile: `s.changes` undefined).

- [ ] **Step 3: Implement the changes stream**

Append to `MacSlowCooker/Settings.swift`:

```swift
extension Settings {

    /// Yields once per mutation of any tracked property.
    /// Re-arms `withObservationTracking` automatically after each yield.
    var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let tracker = SettingsChangeTracker(settings: self) {
                continuation.yield(())
            }
            Task { @MainActor in tracker.start() }
            continuation.onTermination = { _ in tracker.cancel() }
        }
    }
}

@MainActor
private final class SettingsChangeTracker {
    private weak var settings: Settings?
    private let onChange: () -> Void
    private var cancelled = false

    init(settings: Settings, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange
    }

    func start() {
        guard !cancelled, let settings else { return }
        withObservationTracking {
            _ = settings.potStyle
            _ = settings.flameAnimation
            _ = settings.boilingTrigger
        } onChange: { [weak self] in
            // onChange fires synchronously *before* the mutation completes.
            // Hop to a Task so the new value is observable when downstream
            // consumers run, and so we can re-arm tracking.
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled else { return }
                self.onChange()
                self.start()
            }
        }
    }

    nonisolated func cancel() {
        Task { @MainActor in self.cancelled = true }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/SettingsTests/testChangesStreamYieldsOnEachMutation
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MacSlowCooker/Settings.swift MacSlowCookerTests/SettingsTests.swift
git commit -m "feat: add Settings.changes AsyncStream for observation"
```

---

## Task 5: `computeBoiling` pure function

**Files:**
- Create: `MacSlowCooker/DockIconAnimator.swift` (initial — only the static helper)
- Create: `MacSlowCookerTests/BoilingTriggerTests.swift`

`computeBoiling` is the testable core of boiling decision. We add it first, before the surrounding animator.

- [ ] **Step 1: Write failing parameterized tests**

Write `MacSlowCookerTests/BoilingTriggerTests.swift`:

```swift
import XCTest
@testable import MacSlowCooker

final class BoilingTriggerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(usage: Double = 0,
                        temperature: Double? = nil,
                        thermalPressure: String? = nil) -> GPUSample {
        GPUSample(timestamp: Date(),
                  gpuUsage: usage,
                  temperature: temperature,
                  thermalPressure: thermalPressure,
                  power: nil,
                  anePower: nil,
                  aneUsage: nil)
    }

    // MARK: - .temperature mode

    func testTemperatureNilIsNotBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .temperature, sample: sample(temperature: nil),
            aboveThresholdSince: nil, now: now)
        XCTAssertFalse(r.isBoiling)
        XCTAssertNil(r.newAboveThresholdSince)
    }

    func testTemperatureBelowThresholdIsNotBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .temperature, sample: sample(temperature: 84.9),
            aboveThresholdSince: nil, now: now)
        XCTAssertFalse(r.isBoiling)
    }

    func testTemperatureAtThresholdIsBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .temperature, sample: sample(temperature: 85),
            aboveThresholdSince: nil, now: now)
        XCTAssertTrue(r.isBoiling)
    }

    func testTemperatureAboveThresholdIsBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .temperature, sample: sample(temperature: 92),
            aboveThresholdSince: nil, now: now)
        XCTAssertTrue(r.isBoiling)
    }

    // MARK: - .thermalPressure mode

    func testThermalPressureNominalIsNotBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .thermalPressure, sample: sample(thermalPressure: "Nominal"),
            aboveThresholdSince: nil, now: now)
        XCTAssertFalse(r.isBoiling)
    }

    func testThermalPressureFairIsNotBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .thermalPressure, sample: sample(thermalPressure: "Fair"),
            aboveThresholdSince: nil, now: now)
        XCTAssertFalse(r.isBoiling)
    }

    func testThermalPressureSeriousIsBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .thermalPressure, sample: sample(thermalPressure: "Serious"),
            aboveThresholdSince: nil, now: now)
        XCTAssertTrue(r.isBoiling)
    }

    func testThermalPressureCriticalIsBoiling() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .thermalPressure, sample: sample(thermalPressure: "Critical"),
            aboveThresholdSince: nil, now: now)
        XCTAssertTrue(r.isBoiling)
    }

    // MARK: - .combined mode

    func testCombinedHighUsageStartsTimer() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .combined, sample: sample(usage: 0.95),
            aboveThresholdSince: nil, now: now)
        XCTAssertFalse(r.isBoiling)                      // Not yet 5s
        XCTAssertEqual(r.newAboveThresholdSince, now)    // Timer started
    }

    func testCombinedHighUsageBefore5sIsNotBoiling() {
        let started = now.addingTimeInterval(-4.9)
        let r = DockIconAnimator.computeBoiling(
            trigger: .combined, sample: sample(usage: 0.95),
            aboveThresholdSince: started, now: now)
        XCTAssertFalse(r.isBoiling)
    }

    func testCombinedHighUsageAfter5sIsBoiling() {
        let started = now.addingTimeInterval(-5.1)
        let r = DockIconAnimator.computeBoiling(
            trigger: .combined, sample: sample(usage: 0.95),
            aboveThresholdSince: started, now: now)
        XCTAssertTrue(r.isBoiling)
    }

    func testCombinedDropResetsTimer() {
        let started = now.addingTimeInterval(-3.0)
        let r = DockIconAnimator.computeBoiling(
            trigger: .combined, sample: sample(usage: 0.4),
            aboveThresholdSince: started, now: now)
        XCTAssertFalse(r.isBoiling)
        XCTAssertNil(r.newAboveThresholdSince)
    }

    func testCombinedThermalPressureSeriousImmediatelyBoils() {
        let r = DockIconAnimator.computeBoiling(
            trigger: .combined,
            sample: sample(usage: 0.1, thermalPressure: "Serious"),
            aboveThresholdSince: nil, now: now)
        XCTAssertTrue(r.isBoiling)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/BoilingTriggerTests
```
Expected: FAIL (compile: `DockIconAnimator` undefined).

- [ ] **Step 3: Create the animator stub with only `computeBoiling`**

Write `MacSlowCooker/DockIconAnimator.swift`:

```swift
import Foundation

@MainActor
final class DockIconAnimator {

    /// Pure function: compute boiling decision from inputs.
    /// Tested directly by BoilingTriggerTests.
    static func computeBoiling(
        trigger: BoilingTrigger,
        sample: GPUSample,
        aboveThresholdSince: Date?,
        now: Date
    ) -> (isBoiling: Bool, newAboveThresholdSince: Date?) {

        switch trigger {
        case .temperature:
            let boiling = (sample.temperature ?? 0) >= 85
            return (isBoiling: boiling, newAboveThresholdSince: nil)

        case .thermalPressure:
            let boiling = ["Serious", "Critical"].contains(sample.thermalPressure ?? "")
            return (isBoiling: boiling, newAboveThresholdSince: nil)

        case .combined:
            let highUsage = sample.gpuUsage >= 0.9
            let newSince: Date? = highUsage ? (aboveThresholdSince ?? now) : nil
            let sustained = newSince.map { now.timeIntervalSince($0) >= 5.0 } ?? false
            let pressured = ["Serious", "Critical"].contains(sample.thermalPressure ?? "")
            return (isBoiling: sustained || pressured, newAboveThresholdSince: newSince)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/BoilingTriggerTests
```
Expected: 12 tests pass.

- [ ] **Step 5: Commit**

```bash
git add MacSlowCooker/DockIconAnimator.swift MacSlowCookerTests/BoilingTriggerTests.swift MacSlowCooker.xcodeproj
git commit -m "feat: add DockIconAnimator.computeBoiling pure function with tests"
```

---

## Task 6: Animator core — interpolation tick

**Files:**
- Modify: `MacSlowCooker/DockIconAnimator.swift`
- Create: `MacSlowCookerTests/DockIconAnimatorTests.swift`

This task introduces the `DockIconAnimator` instance with state, `init`, `update(sample:)`, the timer, and the interpolation loop. We use a mock renderer in tests to capture every `IconState`.

- [ ] **Step 1: Write a renderer-capturing helper**

Append to `MacSlowCookerTests/TestClock.swift` (single helper file; the new type lives next to TestClock):

```swift
import AppKit

/// Captures every IconState the animator renders.
final class CapturingRenderer: PotRenderer {
    private(set) static var captured: [IconState] = []
    static let lock = NSLock()

    static func reset() {
        lock.lock(); captured.removeAll(); lock.unlock()
    }

    static func render(state: IconState) -> NSImage {
        lock.lock(); captured.append(state); lock.unlock()
        return NSImage(size: iconSize)
    }
}
```

- [ ] **Step 2: Write failing interpolation tests**

Write `MacSlowCookerTests/DockIconAnimatorTests.swift`:

```swift
import XCTest
@testable import MacSlowCooker

@MainActor
final class DockIconAnimatorTests: XCTestCase {

    private var defaults: UserDefaults!
    private var settings: Settings!
    private var clock: TestClock!
    private let suiteName = "com.macslowcooker.tests.animator"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
        settings = Settings(defaults: defaults)
        clock = TestClock()
        CapturingRenderer.reset()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeAnimator() -> DockIconAnimator {
        DockIconAnimator(settings: settings,
                         renderer: CapturingRenderer.self,
                         clock: clock,
                         autostartTimer: false)
    }

    private func sample(usage: Double = 0,
                        temperature: Double? = nil,
                        thermalPressure: String? = nil) -> GPUSample {
        GPUSample(timestamp: clock.now,
                  gpuUsage: usage,
                  temperature: temperature,
                  thermalPressure: thermalPressure,
                  power: nil, anePower: nil, aneUsage: nil)
    }

    // MARK: - Interpolation

    func testInterpolationProgressesTowardsTarget() {
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 1.0))

        // Drive 10 ticks of 100 ms each
        for _ in 0..<10 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }

        let last = CapturingRenderer.captured.last!
        // 1 - exp(-1.0 / 0.7) ≈ 0.76
        XCTAssertGreaterThan(last.displayedUsage, 0.70)
        XCTAssertLessThan(last.displayedUsage, 0.82)
    }

    func testInterpolationConvergesAtSteadyState() {
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5))

        for _ in 0..<60 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }

        let last = CapturingRenderer.captured.last!
        XCTAssertEqual(last.displayedUsage, 0.5, accuracy: 0.01)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/DockIconAnimatorTests
```
Expected: FAIL (compile: `init`/`update`/`tickForTesting`/`setConnected` missing).

- [ ] **Step 4: Implement the interpolation core**

Replace `MacSlowCooker/DockIconAnimator.swift` (full file):

```swift
import AppKit
import Foundation

@MainActor
final class DockIconAnimator {

    // MARK: - Constants

    static let tickInterval: TimeInterval               = 1.0 / 10.0   // 10 fps
    static let interpolationTimeConstant: TimeInterval  = 0.7
    static let boilingFadeTimeConstant: TimeInterval    = 0.6
    static let wiggleSpeed: Double                      = 4.0          // rad/s

    // MARK: - Dependencies

    private let settings: Settings
    private let renderer: PotRenderer.Type
    private let clock: any Clock

    // MARK: - State

    private var displayedUsage: Double = 0
    private var targetUsage: Double = 0

    private var wigglePhase: Double = 0

    private var aboveThresholdSince: Date?
    private var isBoiling: Bool = false
    private var boilingIntensity: Double = 0

    private var isConnected: Bool = false
    private var latestSample: GPUSample?
    private var isSystemAsleep: Bool = false

    private var lastRenderedHash: Int = 0

    private var timer: Timer?
    private let autostartTimer: Bool

    // MARK: - Init

    init(settings: Settings = .shared,
         renderer: PotRenderer.Type = DutchOvenRenderer.self,
         clock: any Clock = SystemClock(),
         autostartTimer: Bool = true) {
        self.settings = settings
        self.renderer = renderer
        self.clock = clock
        self.autostartTimer = autostartTimer
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Public API

    func update(sample: GPUSample) {
        latestSample = sample
        targetUsage = sample.gpuUsage
        // Boiling/wiggle wiring lands in later tasks.
        ensureTimerRunning()
    }

    func setConnected(_ connected: Bool) {
        isConnected = connected
        if !connected {
            targetUsage = 0
        }
        ensureTimerRunning()
    }

    /// Synchronous tick for tests — bypasses Timer.
    func tickForTesting() {
        tick(dt: Self.tickInterval)
    }

    // MARK: - Timer

    private func ensureTimerRunning() {
        guard autostartTimer else { return }
        if timer == nil && !isSystemAsleep {
            timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick(dt: Self.tickInterval) }
            }
            tick(dt: Self.tickInterval)
        }
    }

    // MARK: - Tick

    private func tick(dt: TimeInterval) {
        // Interpolation
        let α = 1 - exp(-dt / Self.interpolationTimeConstant)
        displayedUsage += (targetUsage - displayedUsage) * α

        let state = IconState(
            displayedUsage:    displayedUsage,
            temperature:       latestSample?.temperature,
            isConnected:       isConnected,
            flameWigglePhase:  wigglePhase,
            flameWiggleEnabled: false,         // wired in Task 7
            isBoiling:         isBoiling,
            boilingIntensity:  boilingIntensity)

        _ = renderer.render(state: state)
    }

    // MARK: - Pure helpers

    static func computeBoiling(
        trigger: BoilingTrigger,
        sample: GPUSample,
        aboveThresholdSince: Date?,
        now: Date
    ) -> (isBoiling: Bool, newAboveThresholdSince: Date?) {

        switch trigger {
        case .temperature:
            let boiling = (sample.temperature ?? 0) >= 85
            return (isBoiling: boiling, newAboveThresholdSince: nil)

        case .thermalPressure:
            let boiling = ["Serious", "Critical"].contains(sample.thermalPressure ?? "")
            return (isBoiling: boiling, newAboveThresholdSince: nil)

        case .combined:
            let highUsage = sample.gpuUsage >= 0.9
            let newSince: Date? = highUsage ? (aboveThresholdSince ?? now) : nil
            let sustained = newSince.map { now.timeIntervalSince($0) >= 5.0 } ?? false
            let pressured = ["Serious", "Critical"].contains(sample.thermalPressure ?? "")
            return (isBoiling: sustained || pressured, newAboveThresholdSince: newSince)
        }
    }
}
```

`renderer:` defaults to `DutchOvenRenderer.self` — that type does not yet exist. Add a temporary stub now so the file compiles. Append to `MacSlowCooker/DutchOvenRenderer.swift` (creating the file, fully implemented in Task 10):

Write `MacSlowCooker/DutchOvenRenderer.swift`:

```swift
import AppKit

/// Stub. Real implementation lands in Task 10.
enum DutchOvenRenderer: PotRenderer {
    static func render(state: IconState) -> NSImage {
        NSImage(size: iconSize)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/DockIconAnimatorTests
```
Expected: 2 tests pass. BoilingTriggerTests still pass too.

- [ ] **Step 6: Commit**

```bash
git add MacSlowCooker/DockIconAnimator.swift MacSlowCooker/DutchOvenRenderer.swift \
        MacSlowCookerTests/DockIconAnimatorTests.swift MacSlowCookerTests/TestClock.swift \
        MacSlowCooker.xcodeproj
git commit -m "feat: add DockIconAnimator interpolation tick with TestClock injection"
```

---

## Task 7: Animator wiggle phase + boiling fade

**Files:**
- Modify: `MacSlowCooker/DockIconAnimator.swift`
- Modify: `MacSlowCookerTests/DockIconAnimatorTests.swift`

Add wiggle phase advancement (gated on `flameAnimation`) and boiling fade-in/out via exponential lerp. Wire `evaluateBoiling` into `update(sample:)`.

- [ ] **Step 1: Add failing tests**

Append inside `DockIconAnimatorTests`:

```swift
    // MARK: - Wiggle

    func testWiggleAdvancesWhenEnabled() {
        settings.flameAnimation = .wiggle
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5))

        let phaseBefore = CapturingRenderer.captured.last!.flameWigglePhase
        clock.advance(by: 0.1)
        animator.tickForTesting()
        let phaseAfter = CapturingRenderer.captured.last!.flameWigglePhase

        XCTAssertNotEqual(phaseBefore, phaseAfter)
        XCTAssertTrue(CapturingRenderer.captured.last!.flameWiggleEnabled)
    }

    func testWiggleStaysWhenDisabled() {
        settings.flameAnimation = .interpolation
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5))

        for _ in 0..<5 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        let last = CapturingRenderer.captured.last!
        XCTAssertEqual(last.flameWigglePhase, 0, accuracy: 1e-9)
        XCTAssertFalse(last.flameWiggleEnabled)
    }

    // MARK: - Boiling fade

    func testBoilingFadesIn() {
        settings.boilingTrigger = .temperature
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5, temperature: 90))

        for _ in 0..<10 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }

        let last = CapturingRenderer.captured.last!
        XCTAssertTrue(last.isBoiling)
        XCTAssertGreaterThan(last.boilingIntensity, 0.8)
    }

    func testBoilingFadesOut() {
        settings.boilingTrigger = .temperature
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5, temperature: 90))
        for _ in 0..<10 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        XCTAssertGreaterThan(CapturingRenderer.captured.last!.boilingIntensity, 0.8)

        animator.update(sample: sample(usage: 0.5, temperature: 60))
        for _ in 0..<15 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        let last = CapturingRenderer.captured.last!
        XCTAssertFalse(last.isBoiling)
        XCTAssertLessThan(last.boilingIntensity, 0.2)
    }

    func testCombinedTrigger5sPersistence() {
        settings.boilingTrigger = .combined
        let animator = makeAnimator()
        animator.setConnected(true)

        // 4.9s of high usage → not boiling
        animator.update(sample: sample(usage: 0.95))
        clock.advance(by: 4.9)
        animator.update(sample: sample(usage: 0.95))
        animator.tickForTesting()
        XCTAssertFalse(CapturingRenderer.captured.last!.isBoiling)

        // Push past 5s
        clock.advance(by: 0.3)
        animator.update(sample: sample(usage: 0.95))
        animator.tickForTesting()
        XCTAssertTrue(CapturingRenderer.captured.last!.isBoiling)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/DockIconAnimatorTests
```
Expected: at least 4 new tests fail (wiggle phase not advancing, boiling never set).

- [ ] **Step 3: Implement wiggle and boiling fade in the tick**

Replace `update(sample:)` and `tick(dt:)` in `MacSlowCooker/DockIconAnimator.swift` (rest of file unchanged from Task 6):

```swift
    func update(sample: GPUSample) {
        latestSample = sample
        targetUsage = sample.gpuUsage
        evaluateBoiling(sample: sample)
        ensureTimerRunning()
    }

    private func evaluateBoiling(sample: GPUSample) {
        let result = Self.computeBoiling(
            trigger: settings.boilingTrigger,
            sample: sample,
            aboveThresholdSince: aboveThresholdSince,
            now: clock.now)
        isBoiling = result.isBoiling
        aboveThresholdSince = result.newAboveThresholdSince
    }

    private func tick(dt: TimeInterval) {
        // Interpolation
        let α = 1 - exp(-dt / Self.interpolationTimeConstant)
        displayedUsage += (targetUsage - displayedUsage) * α

        // Wiggle
        let wiggleEnabled = settings.flameAnimation.hasWiggle
        if wiggleEnabled {
            wigglePhase = (wigglePhase + dt * Self.wiggleSpeed)
                .truncatingRemainder(dividingBy: .pi * 2)
        }

        // Boiling fade
        let βb = 1 - exp(-dt / Self.boilingFadeTimeConstant)
        let boilingTarget: Double = isBoiling ? 1.0 : 0.0
        boilingIntensity += (boilingTarget - boilingIntensity) * βb

        let state = IconState(
            displayedUsage:    displayedUsage,
            temperature:       latestSample?.temperature,
            isConnected:       isConnected,
            flameWigglePhase:  wigglePhase,
            flameWiggleEnabled: wiggleEnabled,
            isBoiling:         isBoiling,
            boilingIntensity:  boilingIntensity)

        _ = renderer.render(state: state)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/DockIconAnimatorTests
```
Expected: all DockIconAnimatorTests pass (including the originals from Task 6).

- [ ] **Step 5: Commit**

```bash
git add MacSlowCooker/DockIconAnimator.swift MacSlowCookerTests/DockIconAnimatorTests.swift
git commit -m "feat: add wiggle phase advancement and boiling fade to animator"
```

---

## Task 8: Animator timer lifecycle, sleep, settings change, reconnect

**Files:**
- Modify: `MacSlowCooker/DockIconAnimator.swift`
- Modify: `MacSlowCookerTests/DockIconAnimatorTests.swift`

Add `setSystemAsleep`, `settingsDidChange`, the `needsAnimation()` self-stop logic, and `aboveThresholdSince` reset on reconnect / boiling-mode change.

- [ ] **Step 1: Add failing tests**

Append inside `DockIconAnimatorTests`:

```swift
    // MARK: - Timer lifecycle

    func testIdleAnimatorStopsTimer() {
        settings.flameAnimation = .none
        let animator = DockIconAnimator(settings: settings,
                                        renderer: CapturingRenderer.self,
                                        clock: clock,
                                        autostartTimer: true)
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0))

        // Drive simulated ticks until interpolation converges
        for _ in 0..<30 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        XCTAssertFalse(animator.isTimerRunningForTesting)
    }

    func testWiggleKeepsTimerRunning() {
        settings.flameAnimation = .wiggle
        let animator = DockIconAnimator(settings: settings,
                                        renderer: CapturingRenderer.self,
                                        clock: clock,
                                        autostartTimer: true)
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5))

        for _ in 0..<30 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        XCTAssertTrue(animator.isTimerRunningForTesting)
    }

    // MARK: - System sleep

    func testSystemSleepStopsTimer() {
        settings.flameAnimation = .both
        let animator = DockIconAnimator(settings: settings,
                                        renderer: CapturingRenderer.self,
                                        clock: clock,
                                        autostartTimer: true)
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5))
        XCTAssertTrue(animator.isTimerRunningForTesting)

        animator.setSystemAsleep(true)
        XCTAssertFalse(animator.isTimerRunningForTesting)
    }

    func testSystemWakeRestartsAnimation() {
        settings.flameAnimation = .both
        let animator = DockIconAnimator(settings: settings,
                                        renderer: CapturingRenderer.self,
                                        clock: clock,
                                        autostartTimer: true)
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5))
        animator.setSystemAsleep(true)
        XCTAssertFalse(animator.isTimerRunningForTesting)

        animator.setSystemAsleep(false)
        XCTAssertTrue(animator.isTimerRunningForTesting)
    }

    // MARK: - Disconnect / reconnect

    func testDisconnectResetsBoiling() {
        settings.boilingTrigger = .temperature
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.5, temperature: 90))
        animator.tickForTesting()
        XCTAssertTrue(CapturingRenderer.captured.last!.isBoiling)

        animator.setConnected(false)
        animator.tickForTesting()
        XCTAssertFalse(CapturingRenderer.captured.last!.isBoiling)
    }

    func testReconnectRestartsCombinedTimer() {
        settings.boilingTrigger = .combined
        let animator = makeAnimator()

        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.95))
        XCTAssertNotNil(animator.aboveThresholdSinceForTesting)

        animator.setConnected(false)
        XCTAssertNil(animator.aboveThresholdSinceForTesting)

        clock.advance(by: 30)
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.95))
        XCTAssertEqual(animator.aboveThresholdSinceForTesting, clock.now)
    }

    // MARK: - Settings change

    func testSettingsChangeResetsCombinedTimerWhenSwitchingMode() {
        settings.boilingTrigger = .combined
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0.95))
        XCTAssertNotNil(animator.aboveThresholdSinceForTesting)

        settings.boilingTrigger = .temperature
        animator.settingsDidChange()
        XCTAssertNil(animator.aboveThresholdSinceForTesting)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/DockIconAnimatorTests
```
Expected: new tests fail (compile or assertions).

- [ ] **Step 3: Implement the lifecycle methods**

Add these methods to `MacSlowCooker/DockIconAnimator.swift` (other methods unchanged):

```swift
    // MARK: - Public API additions

    func setSystemAsleep(_ asleep: Bool) {
        isSystemAsleep = asleep
        if asleep {
            timer?.invalidate()
            timer = nil
        } else {
            ensureTimerRunning()
        }
    }

    func settingsDidChange() {
        if settings.boilingTrigger != .combined {
            aboveThresholdSince = nil
        }
        ensureTimerRunning()
    }

    // MARK: - Test introspection

    var isTimerRunningForTesting: Bool { timer != nil }
    var aboveThresholdSinceForTesting: Date? { aboveThresholdSince }
```

Update `setConnected` (replace its body) and `update` to integrate with the lifecycle:

```swift
    func update(sample: GPUSample) {
        latestSample = sample
        targetUsage = sample.gpuUsage
        evaluateBoiling(sample: sample)
        ensureTimerRunning()
    }

    func setConnected(_ connected: Bool) {
        isConnected = connected
        if !connected {
            targetUsage = 0
            isBoiling = false
            aboveThresholdSince = nil
        }
        ensureTimerRunning()
    }
```

Add `needsAnimation()` and update the tick to self-stop:

```swift
    private func needsAnimation() -> Bool {
        if isSystemAsleep { return false }
        if settings.flameAnimation.hasWiggle { return true }
        if abs(displayedUsage - targetUsage) > 0.005 { return true }
        let boilingTarget: Double = isBoiling ? 1.0 : 0.0
        if abs(boilingIntensity - boilingTarget) > 0.005 { return true }
        return false
    }
```

Append a self-stop check at the end of `tick(dt:)`:

```swift
        if !needsAnimation() {
            timer?.invalidate()
            timer = nil
        }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/DockIconAnimatorTests
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add MacSlowCooker/DockIconAnimator.swift MacSlowCookerTests/DockIconAnimatorTests.swift
git commit -m "feat: add timer lifecycle, sleep, settings, and reconnect handling to animator"
```

---

## Task 9: Animator visualHash dedup

**Files:**
- Modify: `MacSlowCooker/DockIconAnimator.swift`
- Modify: `MacSlowCookerTests/DockIconAnimatorTests.swift`

Skip rendering when the new `IconState.visualHash` matches the previous frame, so `NSApp.applicationIconImage` is not assigned redundantly.

- [ ] **Step 1: Add failing dedup test**

Append inside `DockIconAnimatorTests`:

```swift
    // MARK: - Visual hash dedup

    func testNoRenderWhenStateUnchanged() {
        settings.flameAnimation = .none
        let animator = makeAnimator()
        animator.setConnected(true)
        animator.update(sample: sample(usage: 0))

        // Drive ticks until convergence
        for _ in 0..<60 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        let calls1 = CapturingRenderer.captured.count

        // Several more ticks at the same steady state
        for _ in 0..<10 {
            clock.advance(by: 0.1)
            animator.tickForTesting()
        }
        let calls2 = CapturingRenderer.captured.count

        XCTAssertEqual(calls1, calls2, "renderer should be skipped when state is unchanged")
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/DockIconAnimatorTests/testNoRenderWhenStateUnchanged
```
Expected: FAIL (renderer keeps being called).

- [ ] **Step 3: Add dedup gate in tick**

In `MacSlowCooker/DockIconAnimator.swift`, replace the bottom of `tick(dt:)` (where `_ = renderer.render(state: state)` was) with:

```swift
        let hash = state.visualHash
        if hash != lastRenderedHash {
            let image = renderer.render(state: state)
            NSApp.applicationIconImage = image
            lastRenderedHash = hash
        }

        if !needsAnimation() {
            timer?.invalidate()
            timer = nil
        }
```

In tests, `NSApp.applicationIconImage = image` may run inside an XCTest harness — fine on macOS, no UI side effects we care about.

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/DockIconAnimatorTests
```
Expected: all tests pass (including the new dedup test).

- [ ] **Step 5: Commit**

```bash
git add MacSlowCooker/DockIconAnimator.swift MacSlowCookerTests/DockIconAnimatorTests.swift
git commit -m "perf: skip Dock icon update when IconState visualHash unchanged"
```

---

## Task 10: `DutchOvenRenderer` — real implementation

**Files:**
- Modify: `MacSlowCooker/DutchOvenRenderer.swift` (replace stub)
- Create: `MacSlowCookerTests/DutchOvenRendererTests.swift`

Implements the Dutch-oven + flame Core Graphics drawing per spec §4.2. Smoke tests only — no pixel comparison.

- [ ] **Step 1: Write failing smoke tests**

Write `MacSlowCookerTests/DutchOvenRendererTests.swift`:

```swift
import XCTest
import AppKit
@testable import MacSlowCooker

final class DutchOvenRendererTests: XCTestCase {

    private func state(usage: Double = 0,
                       isConnected: Bool = true,
                       boilingIntensity: Double = 0,
                       wiggleEnabled: Bool = false) -> IconState {
        IconState(displayedUsage: usage,
                  temperature: 50,
                  isConnected: isConnected,
                  flameWigglePhase: 1.23,
                  flameWiggleEnabled: wiggleEnabled,
                  isBoiling: boilingIntensity > 0,
                  boilingIntensity: boilingIntensity)
    }

    func testProducesNonEmptyImageForRepresentativeStates() {
        let states: [IconState] = [
            state(usage: 0,    isConnected: false),               // Disconnected
            state(usage: 0.05),                                   // Idle
            state(usage: 0.45),                                   // Simmer
            state(usage: 0.75, wiggleEnabled: true),              // High + wiggle
            state(usage: 0.95, boilingIntensity: 1.0)             // Boiling
        ]

        for s in states {
            let img = DutchOvenRenderer.render(state: s)
            XCTAssertEqual(img.size, DutchOvenRenderer.iconSize)
            XCTAssertFalse(img.representations.isEmpty,
                           "renderer must produce a bitmap rep for \(s)")
        }
    }

    func testDoesNotCrashOnExtremes() {
        for u in stride(from: 0.0, through: 1.0, by: 0.05) {
            for connected in [true, false] {
                for boiling in [0.0, 0.5, 1.0] {
                    let s = state(usage: u,
                                  isConnected: connected,
                                  boilingIntensity: boiling,
                                  wiggleEnabled: true)
                    _ = DutchOvenRenderer.render(state: s)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (the stub returns an empty image)**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/DutchOvenRendererTests
```
Expected: FAIL (`representations` is empty).

- [ ] **Step 3: Implement the renderer**

Replace `MacSlowCooker/DutchOvenRenderer.swift` (full file):

```swift
import AppKit
import CoreGraphics
import os.log

private let renderLog = OSLog(subsystem: "com.macslowcooker", category: "render")

enum DutchOvenRenderer: PotRenderer {

    // MARK: - Public

    static func render(state: IconState) -> NSImage {
        let size = iconSize
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            os_log("CGContext creation failed", log: renderLog, type: .error)
            return NSImage(size: size)
        }

        let rect = CGRect(origin: .zero, size: size)
        if state.isConnected {
            drawFlame(in: ctx, rect: rect, state: state)
            drawPotBody(in: ctx, rect: rect)
            drawSteamAndLid(in: ctx, rect: rect, state: state)
        } else {
            drawDisconnectedPot(in: ctx, rect: rect)
        }

        guard let cgImage = ctx.makeImage() else {
            os_log("CGContext makeImage failed", log: renderLog, type: .error)
            return NSImage(size: size)
        }
        return NSImage(cgImage: cgImage, size: size)
    }

    // MARK: - Disconnected pot (gray, no flame)

    private static func drawDisconnectedPot(in ctx: CGContext, rect: CGRect) {
        let cx = rect.width / 2
        let body = CGPath(roundedRect:
            CGRect(x: rect.width * 0.14, y: rect.height * 0.20,
                   width: rect.width * 0.72, height: rect.height * 0.32),
            cornerWidth: 24, cornerHeight: 24, transform: nil)
        ctx.setFillColor(NSColor(white: 0.22, alpha: 1).cgColor)
        ctx.addPath(body); ctx.fillPath()

        // Lid
        ctx.setFillColor(NSColor(white: 0.30, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.width * 0.16, y: rect.height * 0.50,
                                   width: rect.width * 0.68, height: rect.height * 0.06))

        drawCenteredLabel("--", in: ctx, rect: rect, color: .gray, fontSize: 96)
    }

    // MARK: - Flame

    private static func drawFlame(in ctx: CGContext, rect: CGRect, state: IconState) {
        let usage = max(0, min(1, state.displayedUsage))
        guard usage > 0.01 else { return }

        let cx = rect.width / 2
        let baseY = rect.height * 0.18
        let height = rect.height * 0.18 * usage
        let halfWidth = rect.width * 0.18 * sqrt(usage)

        // Optional wiggle distortion of bezier control points
        let phase = state.flameWiggleEnabled ? state.flameWigglePhase : 0
        let wiggleX = sin(phase) * rect.width * 0.01
        let wiggleY = cos(phase * 1.3) * height * 0.06

        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx - halfWidth, y: baseY))
        path.addQuadCurve(
            to: CGPoint(x: cx + wiggleX, y: baseY + height + wiggleY),
            control: CGPoint(x: cx - halfWidth * 0.5 + wiggleX, y: baseY + height * 0.7))
        path.addQuadCurve(
            to: CGPoint(x: cx + halfWidth, y: baseY),
            control: CGPoint(x: cx + halfWidth * 0.6 - wiggleX, y: baseY + height * 0.5))
        path.closeSubpath()

        // Color shifts redder at high usage
        let red:    CGFloat = usage < 0.6 ? 1.0 : 1.0
        let green:  CGFloat = usage < 0.6 ? 0.7 : (usage < 0.85 ? 0.55 : 0.3)
        let blue:   CGFloat = 0.15

        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 0.95))
        ctx.addPath(path); ctx.fillPath()

        // Inner brighter flame
        let innerPath = CGMutablePath()
        innerPath.move(to: CGPoint(x: cx - halfWidth * 0.5, y: baseY))
        innerPath.addQuadCurve(
            to: CGPoint(x: cx + wiggleX * 0.5, y: baseY + height * 0.85 + wiggleY * 0.5),
            control: CGPoint(x: cx - halfWidth * 0.25, y: baseY + height * 0.5))
        innerPath.addQuadCurve(
            to: CGPoint(x: cx + halfWidth * 0.5, y: baseY),
            control: CGPoint(x: cx + halfWidth * 0.3, y: baseY + height * 0.4))
        innerPath.closeSubpath()
        ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.3, alpha: 0.85))
        ctx.addPath(innerPath); ctx.fillPath()
    }

    // MARK: - Pot body + handles

    private static func drawPotBody(in ctx: CGContext, rect: CGRect) {
        let body = CGPath(
            roundedRect: CGRect(x: rect.width * 0.14,
                                y: rect.height * 0.20,
                                width: rect.width * 0.72,
                                height: rect.height * 0.32),
            cornerWidth: 24, cornerHeight: 24, transform: nil)
        ctx.setFillColor(NSColor(white: 0.10, alpha: 1).cgColor)
        ctx.addPath(body); ctx.fillPath()

        // Handles
        ctx.setStrokeColor(NSColor(white: 0.10, alpha: 1).cgColor)
        ctx.setLineWidth(rect.width * 0.018)
        ctx.setLineCap(.round)

        ctx.move(to: CGPoint(x: rect.width * 0.10, y: rect.height * 0.46))
        ctx.addLine(to: CGPoint(x: rect.width * 0.06, y: rect.height * 0.48))
        ctx.addLine(to: CGPoint(x: rect.width * 0.10, y: rect.height * 0.50))
        ctx.strokePath()

        ctx.move(to: CGPoint(x: rect.width * 0.90, y: rect.height * 0.46))
        ctx.addLine(to: CGPoint(x: rect.width * 0.94, y: rect.height * 0.48))
        ctx.addLine(to: CGPoint(x: rect.width * 0.90, y: rect.height * 0.50))
        ctx.strokePath()
    }

    // MARK: - Steam + lid (with bounce when boiling)

    private static func drawSteamAndLid(in ctx: CGContext, rect: CGRect, state: IconState) {
        let lidY = rect.height * 0.50
        let lidOffset = state.boilingIntensity *
            sin(state.flameWigglePhase * 8) * rect.height * 0.012

        // Lid base
        ctx.setFillColor(NSColor(white: 0.05, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.width * 0.16, y: lidY + lidOffset,
                                   width: rect.width * 0.68, height: rect.height * 0.05))
        // Lid top accent
        ctx.setFillColor(NSColor(white: 0.18, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.width * 0.20, y: lidY + lidOffset + rect.height * 0.008,
                                   width: rect.width * 0.60, height: rect.height * 0.03))
        // Knob
        ctx.setFillColor(NSColor(red: 0.32, green: 0.24, blue: 0.16, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.width / 2 - rect.width * 0.025,
                                   y: lidY + lidOffset + rect.height * 0.04,
                                   width: rect.width * 0.05, height: rect.height * 0.025))

        // Steam
        let count = steamStrandCount(state: state)
        if count == 0 { return }

        ctx.setLineWidth(rect.width * 0.012)
        ctx.setLineCap(.round)
        let steamColor = lerpColor(from: CGColor(red: 1, green: 1, blue: 1, alpha: 0.5),
                                   to:   CGColor(red: 1, green: 0.6, blue: 0.4, alpha: 0.8),
                                   t: state.boilingIntensity)
        ctx.setStrokeColor(steamColor)

        let baseX = rect.width * 0.50
        let stride = rect.width * 0.10
        let topY  = rect.height * 0.78
        let bottomY = rect.height * 0.55

        let strands: [(CGFloat, CGFloat)] = [
            (baseX,            0),
            (baseX - stride,   1),
            (baseX + stride,  -1),
            (baseX + stride*2, 0)
        ]
        for i in 0..<count {
            let (x, sway) = strands[i]
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: bottomY))
            path.addQuadCurve(
                to: CGPoint(x: x + sway * stride * 0.3, y: topY),
                control: CGPoint(x: x - sway * stride * 0.4, y: (bottomY + topY) / 2))
            ctx.addPath(path); ctx.strokePath()
        }
    }

    private static func steamStrandCount(state: IconState) -> Int {
        let usage = state.displayedUsage
        let base: Int
        switch usage {
        case ..<0.2:  base = 0
        case ..<0.6:  base = 1
        case ..<0.9:  base = 2
        default:      base = 2
        }
        // Boiling adds an extra strand once intensity is high enough
        return base + (state.boilingIntensity > 0.5 ? 1 : 0)
    }

    private static func lerpColor(from a: CGColor, to b: CGColor, t: Double) -> CGColor {
        let t = max(0, min(1, t))
        let ac = a.components ?? [1,1,1,1]
        let bc = b.components ?? [1,1,1,1]
        return CGColor(red:   ac[0] * (1-t) + bc[0] * t,
                       green: ac[1] * (1-t) + bc[1] * t,
                       blue:  ac[2] * (1-t) + bc[2] * t,
                       alpha: ac[3] * (1-t) + bc[3] * t)
    }

    // MARK: - Label

    private static func drawCenteredLabel(_ text: String, in ctx: CGContext, rect: CGRect,
                                          color: NSColor, fontSize: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetImageBounds(line, ctx)
        ctx.textPosition = CGPoint(x: (rect.width - bounds.width) / 2,
                                   y: rect.height * 0.30)
        CTLineDraw(line, ctx)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/DutchOvenRendererTests
```
Expected: all 2 renderer tests pass.

- [ ] **Step 5: Run the full test suite to make sure nothing regressed**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: every existing test (Settings, BoilingTrigger, DockIconAnimator, DutchOvenRenderer, plus untouched legacy tests) passes.

- [ ] **Step 6: Commit**

```bash
git add MacSlowCooker/DutchOvenRenderer.swift MacSlowCookerTests/DutchOvenRendererTests.swift MacSlowCooker.xcodeproj
git commit -m "feat: implement DutchOvenRenderer with flame, steam, and boiling lid"
```

---

## Task 11: PreferencesWindowController

**Files:**
- Create: `MacSlowCooker/PreferencesWindowController.swift`

No automated tests — manual verification only (per spec §9.1).

- [ ] **Step 1: Write the controller and SwiftUI view**

Write `MacSlowCooker/PreferencesWindowController.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {

    private let settings: Settings

    init(settings: Settings = .shared) {
        self.settings = settings
        let view = PreferencesView(settings: settings)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "MacSlowCooker 設定"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 380, height: 220))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PreferencesView: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Picker("鍋スタイル", selection: $settings.potStyle) {
                Text("ダッチオーブン").tag(PotStyle.dutchOven)
            }

            Picker("炎アニメーション", selection: $settings.flameAnimation) {
                Text("なし").tag(FlameAnimation.none)
                Text("補間のみ").tag(FlameAnimation.interpolation)
                Text("ゆらぎのみ").tag(FlameAnimation.wiggle)
                Text("両方").tag(FlameAnimation.both)
            }

            Picker("沸騰トリガー", selection: $settings.boilingTrigger) {
                Text("温度 ≥ 85°C").tag(BoilingTrigger.temperature)
                Text("熱ストレス ≥ Serious").tag(BoilingTrigger.thermalPressure)
                Text("組み合わせ（推奨）").tag(BoilingTrigger.combined)
            }
        }
        .padding(20)
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodegen generate
xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add MacSlowCooker/PreferencesWindowController.swift MacSlowCooker.xcodeproj
git commit -m "feat: add PreferencesWindowController with SwiftUI Picker view"
```

---

## Task 12: AppDelegate menu construction

**Files:**
- Modify: `MacSlowCooker/AppDelegate.swift`

Replace the implicit menu setup with a manual `NSApp.mainMenu` build that includes App + Edit + Window menus, so Cmd-C/V/W work in Preferences.

- [ ] **Step 1: Add `buildMainMenu()` and `showPreferences()`**

Replace `MacSlowCooker/AppDelegate.swift` (full file — keep only the parts changed by this task and Task 13; Task 13 will modify it again):

```swift
import AppKit
import os.log

private let log = OSLog(subsystem: "com.macslowcooker", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = GPUDataStore()
    private let xpcClient = XPCClient()
    private lazy var popupController = PopupWindowController(store: store)
    private var preferencesController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        updateDockIcon()
        Task {
            do {
                try await HelperInstaller.installIfNeeded()
                connectXPC()
            } catch {
                os_log("Install failed: %{public}s", log: log, type: .error, error.localizedDescription)
                NSApp.activate(ignoringOtherApps: true)
                showError(error.localizedDescription)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        popupController.toggle()
        return false
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "MacSlowCooker について",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "設定…",
                                   action: #selector(showPreferences),
                                   keyEquivalent: ","))

        let services = NSMenuItem(title: "サービス", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(services)

        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "MacSlowCooker を隠す",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: "ほかを隠す",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "すべてを表示",
                                   action: #selector(NSApplication.unhideAllApplications(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "MacSlowCooker を終了",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu — required for Cmd-C/V/X/A in Preferences
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(NSMenuItem(title: "取り消す",  action: Selector(("undo:")),       keyEquivalent: "z"))
        let redo = NSMenuItem(title: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "カット", action: #selector(NSText.cut(_:)),    keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "コピー", action: #selector(NSText.copy(_:)),   keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "すべて選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Window menu
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウィンドウ")
        windowMenu.addItem(NSMenuItem(title: "しまう",
                                      action: #selector(NSWindow.performMiniaturize(_:)),
                                      keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "拡大/縮小",
                                      action: #selector(NSWindow.performZoom(_:)),
                                      keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "すべてを手前に移動",
                                      action: #selector(NSApplication.arrangeInFront(_:)),
                                      keyEquivalent: ""))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showPreferences() {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController()
        }
        preferencesController?.showWindow()
    }

    // MARK: - XPC (kept from previous version, will be replaced in Task 13)

    private func connectXPC() {
        xpcClient.onSample = { [weak self] sample in
            guard let self else { return }
            store.addSample(sample)
            updateDockIcon()
        }
        xpcClient.onConnected = { [weak self] in
            self?.store.setConnected(true)
            os_log("XPC connected", log: log, type: .info)
        }
        xpcClient.onDisconnected = { [weak self] in
            self?.store.setConnected(false)
            self?.updateDockIcon()
            os_log("XPC disconnected", log: log, type: .info)
        }
        xpcClient.connect()
    }

    private func updateDockIcon() {
        let usage = store.latestSample?.gpuUsage ?? 0
        let connected = store.isConnected
        DispatchQueue.global(qos: .userInteractive).async {
            let image = DockIconRenderer.render(usage: usage, isConnected: connected)
            DispatchQueue.main.async {
                NSApp.applicationIconImage = image
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MacSlowCooker — セットアップエラー"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
```

The current step still depends on the now-deprecated `DockIconRenderer` because the animator wiring lands in Task 13. Keep `DockIconRenderer.swift` for one more task.

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: build succeeds.

- [ ] **Step 3: Manual verification — menu plumbing**

```bash
xcodebuild -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -configuration Debug \
  -derivedDataPath build build CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=K38MBRNKAT
open build/Build/Products/Debug/MacSlowCooker.app
```
- App menu shows MacSlowCooker / 設定… / 終了
- Edit menu present with Cmd-C/V
- Cmd-, opens Preferences window
- In Preferences, you can paste text into a focused field (test by tabbing into a Picker — the menu items should be enabled)

- [ ] **Step 4: Commit**

```bash
git add MacSlowCooker/AppDelegate.swift
git commit -m "feat: add manual main menu with App/Edit/Window submenus"
```

---

## Task 13: AppDelegate animator + sleep wiring

**Files:**
- Modify: `MacSlowCooker/AppDelegate.swift`

Replace the legacy `updateDockIcon()` with `DockIconAnimator`, observe `Settings`, and subscribe to NSWorkspace sleep notifications.

- [ ] **Step 1: Replace AppDelegate to use the animator**

Replace `MacSlowCooker/AppDelegate.swift` (full file):

```swift
import AppKit
import os.log

private let log = OSLog(subsystem: "com.macslowcooker", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = GPUDataStore()
    private let xpcClient = XPCClient()
    private let settings = Settings.shared
    private let animator = DockIconAnimator()

    private lazy var popupController = PopupWindowController(store: store)
    private var preferencesController: PreferencesWindowController?
    private var settingsObservationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        observeSettings()
        observeSystemSleep()
        animator.setConnected(false)   // initial Disconnected paint

        Task {
            do {
                try await HelperInstaller.installIfNeeded()
                connectXPC()
            } catch {
                os_log("Install failed: %{public}s", log: log, type: .error, error.localizedDescription)
                NSApp.activate(ignoringOtherApps: true)
                showError(error.localizedDescription)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        popupController.toggle()
        return false
    }

    // MARK: - Menu (same as Task 12)

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "MacSlowCooker について",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "設定…",
                                   action: #selector(showPreferences),
                                   keyEquivalent: ","))

        let services = NSMenuItem(title: "サービス", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(services)

        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "MacSlowCooker を隠す",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: "ほかを隠す",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "すべてを表示",
                                   action: #selector(NSApplication.unhideAllApplications(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "MacSlowCooker を終了",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(NSMenuItem(title: "取り消す", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "カット",   action: #selector(NSText.cut(_:)),    keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "コピー",   action: #selector(NSText.copy(_:)),   keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "ペースト", action: #selector(NSText.paste(_:)),  keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "すべて選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウィンドウ")
        windowMenu.addItem(NSMenuItem(title: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "拡大/縮小", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "すべてを手前に移動", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showPreferences() {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController()
        }
        preferencesController?.showWindow()
    }

    // MARK: - XPC

    private func connectXPC() {
        xpcClient.onSample = { [weak self] sample in
            guard let self else { return }
            store.addSample(sample)
            animator.update(sample: sample)
        }
        xpcClient.onConnected = { [weak self] in
            self?.store.setConnected(true)
            self?.animator.setConnected(true)
            os_log("XPC connected", log: log, type: .info)
        }
        xpcClient.onDisconnected = { [weak self] in
            self?.store.setConnected(false)
            self?.animator.setConnected(false)
            os_log("XPC disconnected", log: log, type: .info)
        }
        xpcClient.connect()
    }

    // MARK: - Settings observation

    private func observeSettings() {
        settingsObservationTask = Task { @MainActor [animator, settings] in
            for await _ in settings.changes {
                animator.settingsDidChange()
            }
        }
    }

    // MARK: - System sleep

    private func observeSystemSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification,        object: nil, queue: .main) { [weak self] _ in self?.animator.setSystemAsleep(true)  }
        nc.addObserver(forName: NSWorkspace.didWakeNotification,          object: nil, queue: .main) { [weak self] _ in self?.animator.setSystemAsleep(false) }
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,  object: nil, queue: .main) { [weak self] _ in self?.animator.setSystemAsleep(true)  }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,   object: nil, queue: .main) { [weak self] _ in self?.animator.setSystemAsleep(false) }
    }

    // MARK: - Error UI

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MacSlowCooker — セットアップエラー"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: build succeeds. (`DockIconRenderer.swift` is now unused — removed in Task 14.)

- [ ] **Step 3: Run all tests**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add MacSlowCooker/AppDelegate.swift
git commit -m "feat: wire DockIconAnimator + sleep notifications into AppDelegate"
```

---

## Task 14: Cleanup — remove obsolete bar renderer

**Files:**
- Delete: `MacSlowCooker/DockIconRenderer.swift`
- Delete: `MacSlowCookerTests/DockIconRendererTests.swift`

- [ ] **Step 1: Verify nothing in the source tree still references `DockIconRenderer`**

```bash
grep -rn "DockIconRenderer" MacSlowCooker MacSlowCookerTests Shared HelperTool
```
Expected: zero matches (the animator uses `DutchOvenRenderer` directly).

- [ ] **Step 2: Delete the files via git**

```bash
git rm MacSlowCooker/DockIconRenderer.swift MacSlowCookerTests/DockIconRendererTests.swift
```

- [ ] **Step 3: Regenerate project and run all tests**

```bash
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: build + all tests pass.

- [ ] **Step 4: Commit**

```bash
git add MacSlowCooker.xcodeproj
git commit -m "chore: remove obsolete DockIconRenderer in favor of DutchOvenRenderer"
```

---

## Task 15: Final manual verification

This task has no code — it walks the manual checklist from spec §9.3 and acceptance scenarios from §10. Mark each item only after observing the behavior in a real build.

- [ ] **Step 1: Release build with signing**

```bash
xcodebuild -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -configuration Release \
  -derivedDataPath build build \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=K38MBRNKAT
```
Expected: build succeeds.

- [ ] **Step 2: Replace the running app and restart the helper**

```bash
pkill -9 -x MacSlowCooker || true
ditto build/Build/Products/Release/MacSlowCooker.app /Applications/MacSlowCooker.app
sudo launchctl kickstart -k system/com.macslowcooker.helper
open /Applications/MacSlowCooker.app
```

- [ ] **Step 3: Walk the §9.3 checklist**

Verify each:
- [ ] App launches showing the gray "Disconnected" Dutch oven (no flame, "--")
- [ ] Within ~2 s of launch, flame appears at `Idle` height (steady < 20% usage in normal idle)
- [ ] Open Activity Monitor and run a Metal benchmark or `yes > /dev/null` ×8 — flame grows, steam appears
- [ ] After ~5 s of sustained > 90% usage, lid bounces and steam turns reddish (Boiling)
- [ ] Stop the load — within ~1 s the boiling effect fades and flame returns to Idle
- [ ] ⌘, opens Preferences. Cmd-C / Cmd-V work in the form (test by focusing a Picker and using ⌘A)
- [ ] In Preferences switch flameAnimation between `.none` / `.both` — flame freezes/wiggles in real time
- [ ] Switch boilingTrigger between modes — boiling effect updates appropriately
- [ ] Idle CPU (`top -l 1 | grep MacSlowCooker`) drops to ≈ 0 % when flame settled and animation set to `.none`
- [ ] In `.both` mode, CPU stays under ~2 %
- [ ] Sleep the Mac, wake it — animation resumes (verify via Activity Monitor sample post-wake)
- [ ] Restart the helper (`sudo launchctl kickstart -k system/com.macslowcooker.helper`) — animator picks up new samples within a couple of seconds

- [ ] **Step 4: Final summary commit (no code, optional)**

If any spec drift was discovered during manual verification, file a follow-up issue rather than amending the plan.

```bash
gh issue list --label pot-icon-poc
```

---

## Self-Review Notes

- Spec coverage:
  - §1 Overview / scope: covered by Tasks 1–14.
  - §2 Architecture: realised by Tasks 1, 5–13.
  - §3 Data types: Task 1.
  - §4 DutchOvenRenderer: Task 10.
  - §5 DockIconAnimator (incl. constants 5.2, public API 5.3, tick 5.4, needsAnimation 5.5, computeBoiling 5.6, sleep 5.7): Tasks 5–9.
  - §6 PreferencesWindowController: Task 11.
  - §7 AppDelegate integration: Tasks 12 & 13.
  - §8 File changes: enacted across tasks; deletion is Task 14.
  - §9 Testing strategy: Tasks 3, 4, 5, 6, 7, 8, 9, 10 cover automated; Task 15 covers manual.
  - §10 Acceptance scenarios: Task 15.
  - §11 Risks: addressed by the visualHash dedup (Task 9), the explicit sleep handling (Tasks 8 & 13), and TestClock-driven boiling tests (Tasks 5 & 7).
  - §12 Phase 2 items: out of plan scope (tracked as GitHub issues #1, #2).
- Type-name consistency check passed: `PotStyle`, `FlameAnimation`, `BoilingTrigger`, `IconState`, `PotRenderer`, `DutchOvenRenderer`, `DockIconAnimator`, `Settings`, `SettingsChangeTracker`, `Clock`, `SystemClock`, `TestClock`, `CapturingRenderer`, `PreferencesWindowController`, `PreferencesView`, `computeBoiling`, `evaluateBoiling`, `update(sample:)`, `setConnected(_:)`, `setSystemAsleep(_:)`, `settingsDidChange()` — all spelled identically across tasks.
