import Foundation

/// Pure heuristics that drive the cooking metaphor — when does the pot
/// "boil," what temperature stands in for an unreadable sensor, etc.
///
/// Lives in `Shared/` (separate from `DockIconAnimator`) so the helper
/// could one day reuse the same logic for log severity, and so the rules
/// stay testable in isolation. All members are pure / value-only.
enum CookingHeuristics {

    /// Map an OS-reported `ThermalPressure` to a representative
    /// temperature in °C. Used when the SoC temperature sensor isn't
    /// readable (typical on macOS 26 / M3 Ultra) so the renderer's heat
    /// color still tracks something. Numbers chosen to match the visible
    /// color stops in `DutchOvenRenderer.potColor` (50 °C white → 95 °C red).
    static func estimatedTemperature(for thermalPressure: ThermalPressure?) -> Double? {
        switch thermalPressure {
        case .nominal:  return 55
        case .fair:     return 70
        case .serious:  return 85
        case .critical: return 95
        case .none:     return nil
        }
    }

    /// Decide whether the lid should bounce ("boiling animation"). The
    /// rules differ by trigger:
    ///   - `.temperature`: fire above 85 °C
    ///   - `.thermalPressure`: fire on `.serious` / `.critical`
    ///   - `.combined`: fire when GPU usage stays ≥ 90 % for 5 s, or the
    ///     OS reports thermal pressure
    ///
    /// `aboveThresholdSince` is the caller's running record of when the
    /// usage first crossed 90 % (passed back as `newAboveThresholdSince`
    /// so the caller doesn't need its own state machine).
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
            let boiling = sample.thermalPressure?.isPressured ?? false
            return (isBoiling: boiling, newAboveThresholdSince: nil)

        case .combined:
            let highUsage = sample.gpuUsage >= 0.9
            let newSince: Date? = highUsage ? (aboveThresholdSince ?? now) : nil
            let sustained = newSince.map { now.timeIntervalSince($0) >= 5.0 } ?? false
            let pressured = sample.thermalPressure?.isPressured ?? false
            return (isBoiling: sustained || pressured, newAboveThresholdSince: newSince)
        }
    }
}
