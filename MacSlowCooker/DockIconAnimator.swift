import Foundation

@MainActor
final class DockIconAnimator {

    /// Pure function: compute boiling decision from inputs.
    /// Tested directly by BoilingTriggerTests.
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
