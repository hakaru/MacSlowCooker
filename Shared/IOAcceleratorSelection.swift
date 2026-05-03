import Foundation

/// Pure selection logic for `IOAcceleratorReader`. Given a list of accelerator
/// service readings, pick the one whose utilization should drive the dock
/// icon. Extracted so the policy (sort by name, take first usable) can be
/// unit-tested without iterating real IORegistry services.
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

    /// Sort the readings by IORegistry entry name and return the first one
    /// that reports a usable percentage. Sorting + first-match makes the
    /// choice deterministic across reboots, where iteration order from
    /// `IOServiceGetMatchingServices` is otherwise undefined.
    ///
    /// Returns the chosen reading and the full sorted list (for logging),
    /// or nil if none of the services reports a percentage.
    static func choose(from readings: [Reading]) -> (chosen: Reading, sorted: [Reading])? {
        let sorted = readings.sorted { $0.name < $1.name }
        guard let chosen = sorted.first(where: { $0.utilization != nil }) else {
            return nil
        }
        return (chosen, sorted)
    }

    /// Normalize a percentage in [0, 100] to a fraction in [0, 1], clamping
    /// out-of-range readings instead of trusting them blindly.
    static func normalize(percent: Double) -> Double {
        min(1.0, max(0.0, percent / 100.0))
    }
}
