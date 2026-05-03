import Foundation

/// Pure matcher for IOHIDEventSystem temperature sensor names. Decides
/// whether a given sensor "Product" string should be averaged into the
/// representative SoC / GPU temperature.
///
/// On Apple Silicon the relevant names are PMU `tdie*` / `tdev*` / `gpu_*`;
/// on Intel Macs the heat-bearing sensors are typically `GPU Proximity` and
/// the AMD `Graphics` family. We accept anything containing any of those
/// substrings so the same code path covers both architectures.
enum SensorNameMatcher {

    static let acceptedSubstrings: [String] = ["die", "tdev", "gpu", "proximity", "graphics"]

    static func shouldMatch(name: String) -> Bool {
        let lower = name.lowercased()
        return acceptedSubstrings.contains { lower.contains($0) }
    }
}
