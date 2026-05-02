import Foundation

enum PowerMetricsParser {
    /// Parse one plist sample from powermetrics into a GPUSample.
    /// Supports both the legacy keys (capitalized "GPU", "gpu_active_residency")
    /// and the macOS 14+/26 keys (lowercase "gpu", "idle_ratio").
    static func parse(plistData: Data, timestamp: Date) -> GPUSample? {
        guard let dict = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }

        // GPU dict — try both casings
        let gpuDict = (dict["gpu"] as? [String: Any]) ?? (dict["GPU"] as? [String: Any])

        // GPU usage: prefer explicit gpu_active_residency; otherwise compute from idle_ratio
        var gpuUsage: Double?
        if let gpu = gpuDict {
            if let active = gpu["gpu_active_residency"] as? Double {
                gpuUsage = active
            } else if let idle = gpu["idle_ratio"] as? Double {
                gpuUsage = max(0.0, 1.0 - idle)
            }
        }
        // If neither key is present, we can't produce a sample
        guard let usage = gpuUsage else { return nil }

        // Temperature: legacy keys only — not exposed in macOS 26 plist output
        let temperature: Double? = (gpuDict?["GPU Die Temp"] as? Double)
            ?? (gpuDict?["gpu_die_temperature"] as? Double)

        // Power: try legacy keys first, otherwise derive from gpu_energy (mJ) / elapsed_ns
        var power: Double?
        if let p = (gpuDict?["gpu_power_mW"] as? Double).map({ $0 / 1000.0 })
            ?? (gpuDict?["gpu_power"] as? Double)
            ?? (gpuDict?["GPU Power"] as? Double) {
            power = p
        } else if let energyMJ = gpuDict?["gpu_energy"] as? Double,
                  let elapsedNs = dict["elapsed_ns"] as? Double, elapsedNs > 0 {
            // gpu_energy is in mJ over the elapsed window; divide by elapsed seconds → W
            power = (energyMJ / 1000.0) / (elapsedNs / 1_000_000_000.0)
        }

        // ANE usage (legacy): try both casings — usually nil on macOS 26
        let aneDict = (dict["ane"] as? [String: Any]) ?? (dict["ANE"] as? [String: Any])
        let aneUsage: Double? = (aneDict?["ane_active_residency"] as? Double)
            ?? (aneDict?["idle_ratio"] as? Double).map { max(0.0, 1.0 - $0) }

        // ANE power on macOS 26: in dict["processor"]["ane_power"] (mW)
        var anePower: Double?
        if let processor = dict["processor"] as? [String: Any],
           let aneMW = processor["ane_power"] as? Double {
            anePower = aneMW / 1000.0
        } else if let energyMJ = (aneDict?["ane_energy"] as? Double),
                  let elapsedNs = dict["elapsed_ns"] as? Double, elapsedNs > 0 {
            anePower = (energyMJ / 1000.0) / (elapsedNs / 1_000_000_000.0)
        }

        // Thermal pressure: top-level categorical value
        let thermalPressure = dict["thermal_pressure"] as? String

        return GPUSample(
            timestamp: timestamp,
            gpuUsage: min(max(usage, 0.0), 1.0),
            temperature: temperature,
            thermalPressure: thermalPressure,
            power: power,
            anePower: anePower,
            aneUsage: aneUsage.map { min(max($0, 0.0), 1.0) }
        )
    }
}
