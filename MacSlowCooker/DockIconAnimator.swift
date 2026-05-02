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
