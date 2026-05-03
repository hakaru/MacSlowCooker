import AppKit
import Foundation

@MainActor
final class DockIconAnimator {

    // MARK: - Constants

    static let tickInterval: TimeInterval               = 1.0 / 10.0   // 10 fps (full power)
    static let lowPowerTickInterval: TimeInterval       = 1.0 / 5.0    // 5 fps (low power mode)
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
    private var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var lastRenderedHash: Int = 0

    private var timer: Timer?
    private let autostartTimer: Bool
    private var lpmObserver: NSObjectProtocol?

    // MARK: - Init

    init(settings: Settings = .shared,
         renderer: PotRenderer.Type = DutchOvenRenderer.self,
         clock: any Clock = SystemClock(),
         autostartTimer: Bool = true) {
        self.settings = settings
        self.renderer = renderer
        self.clock = clock
        self.autostartTimer = autostartTimer
        observeLowPowerMode()
    }

    deinit {
        timer?.invalidate()
        if let observer = lpmObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Toggle tick rate (10→5 fps) and disable wiggle when Low Power Mode is on.
    /// MacSlowCooker's brand promise is energy-conscious behavior — silently
    /// burning 10 fps + flame wiggle while the OS asks everyone to slow down
    /// would undercut that. Visible status is surfaced in Preferences.
    private func observeLowPowerMode() {
        lpmObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleLowPowerModeChange()
            }
        }
    }

    private func handleLowPowerModeChange() {
        let now = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard now != isLowPowerMode else { return }
        isLowPowerMode = now
        // Restart timer with the new cadence.
        timer?.invalidate()
        timer = nil
        ensureTimerRunning()
    }

    private var currentTickInterval: TimeInterval {
        isLowPowerMode ? Self.lowPowerTickInterval : Self.tickInterval
    }

    // MARK: - Public API

    func update(sample: GPUSample) {
        latestSample = sample
        targetUsage = sample.gpuUsage
        evaluateBoiling(sample: sample)
        if autostartTimer {
            ensureTimerRunning()
        } else {
            tick(dt: 0)
        }
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

    func setConnected(_ connected: Bool) {
        isConnected = connected
        if !connected {
            targetUsage = 0
            isBoiling = false
            aboveThresholdSince = nil
        }
        ensureTimerRunning()
    }

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

    /// Synchronous tick for tests — bypasses Timer.
    func tickForTesting() {
        tick(dt: Self.tickInterval)
    }

    // MARK: - Animation predicate

    private func needsAnimation() -> Bool {
        if isSystemAsleep { return false }
        // Wiggle only matters when there's an active flame to wiggle —
        // i.e., the helper is sending samples. Disconnected → no wiggle.
        // Low Power Mode also forces wiggle off (see observeLowPowerMode).
        if isConnected && !isLowPowerMode && settings.flameAnimation.hasWiggle { return true }
        if abs(displayedUsage - targetUsage) > 0.005 { return true }
        let boilingTarget: Double = isBoiling ? 1.0 : 0.0
        if abs(boilingIntensity - boilingTarget) > 0.005 { return true }
        return false
    }

    // MARK: - Timer

    private func ensureTimerRunning() {
        guard autostartTimer else { return }
        if timer == nil && !isSystemAsleep {
            let interval = currentTickInterval
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.tick(dt: self.currentTickInterval)
                }
            }
            tick(dt: interval)
        }
    }

    // MARK: - Tick

    private func tick(dt: TimeInterval) {
        // Height interpolation — gated on `flameAnimation.hasInterpolation`
        // so the "Off" / "Wiggle" settings really do snap to target.
        if settings.flameAnimation.hasInterpolation {
            let α = 1 - exp(-dt / Self.interpolationTimeConstant)
            displayedUsage += (targetUsage - displayedUsage) * α
        } else {
            displayedUsage = targetUsage
        }

        // Wiggle — only meaningful while connected; disconnected pots are flat gray.
        // Low Power Mode disables wiggle to honor the OS energy hint.
        let wiggleEnabled = isConnected && !isLowPowerMode && settings.flameAnimation.hasWiggle
        if wiggleEnabled {
            wigglePhase = (wigglePhase + dt * Self.wiggleSpeed)
                .truncatingRemainder(dividingBy: .pi * 2)
        }

        // Boiling fade
        let βb = 1 - exp(-dt / Self.boilingFadeTimeConstant)
        let boilingTarget: Double = isBoiling ? 1.0 : 0.0
        boilingIntensity += (boilingTarget - boilingIntensity) * βb

        // When the temperature sensor is unavailable (typical on macOS 26 / M3 Ultra),
        // estimate it from `thermalPressure` so the renderer's pot color still tracks
        // heat instead of staying frozen at the cool baseline.
        let effectiveTemp = latestSample?.temperature
            ?? Self.estimatedTemperature(for: latestSample?.thermalPressure)

        let state = IconState(
            displayedUsage:    displayedUsage,
            temperature:       effectiveTemp,
            isConnected:       isConnected,
            flameWigglePhase:  wigglePhase,
            flameWiggleEnabled: wiggleEnabled,
            isBoiling:         isBoiling,
            boilingIntensity:  boilingIntensity,
            fanRPM:            latestSample?.fanRPM?.max())

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
    }

    // MARK: - Pure helpers

    /// When the SoC temperature sensor isn't readable, derive a representative
    /// temperature from `thermal_pressure` so the renderer's heat color still
    /// reflects something. Numbers chosen to match the visible color stops in
    /// `DutchOvenRenderer.potColor` (50°C white → 95°C red).
    nonisolated static func estimatedTemperature(for thermalPressure: String?) -> Double? {
        switch thermalPressure {
        case "Nominal":  return 55
        case "Fair":     return 70
        case "Serious":  return 85
        case "Critical": return 95
        default:         return nil
        }
    }

    nonisolated static func computeBoiling(
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
