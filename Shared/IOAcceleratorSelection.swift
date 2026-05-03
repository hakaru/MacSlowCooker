import Foundation

/// Pure selection logic for `IOAcceleratorReader`. Given a list of accelerator
/// service readings, decide what utilization the dock icon should display.
/// Extracted so the policy can be unit-tested without iterating real
/// IORegistry services.
enum IOAcceleratorSelection {

    struct Reading: Equatable {
        let name: String
        let className: String
        let utilization: Double?

        init(name: String, className: String, utilization: Double?) {
            self.name = name
            self.className = className
            self.utilization = utilization
        }
    }

    /// Outcome of aggregating across all reporting services.
    struct Selection: Equatable {
        /// Aggregated utilization in [0, 100]. Use `normalize(percent:)` to
        /// convert to a [0, 1] fraction.
        let utilization: Double
        /// All readings sorted by name. Useful for first-read logging so the
        /// user can see which services were detected, in a deterministic
        /// order across reboots.
        let sortedReadings: [Reading]
        /// Number of services that contributed a usable percentage. > 1
        /// indicates a multi-GPU machine (eGPU + iGPU, dual GPU, etc.).
        let contributingCount: Int
    }

    /// Aggregate utilization across reporting services by taking the maximum.
    ///
    /// On multi-GPU machines (eGPU + iGPU, Mac Pro with multiple discrete
    /// GPUs) the most useful single metric for "is my GPU busy" is the
    /// max of all reported percentages — it captures the worst-case load
    /// without averaging away the real bottleneck. Sum would over-count
    /// parallel work, average would understate the busy GPU.
    ///
    /// Returns nil if no service reports a usable percentage.
    static func aggregate(from readings: [Reading]) -> Selection? {
        let sorted = readings.sorted { $0.name < $1.name }
        let usable = sorted.compactMap { $0.utilization }
        guard let maxUtil = usable.max() else { return nil }
        return Selection(
            utilization: maxUtil,
            sortedReadings: sorted,
            contributingCount: usable.count)
    }

    /// Normalize a percentage in [0, 100] to a fraction in [0, 1], clamping
    /// out-of-range readings instead of trusting them blindly.
    static func normalize(percent: Double) -> Double {
        min(1.0, max(0.0, percent / 100.0))
    }
}
