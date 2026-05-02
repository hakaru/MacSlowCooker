import Foundation

enum PowerMetricsParser {
    /// Parse one plist sample from powermetrics into a GPUSample.
    /// Returns nil if the GPU dict is missing or gpu_active_residency is absent.
    static func parse(plistData: Data, timestamp: Date) -> GPUSample? {
        guard let dict = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let gpuDict = dict["GPU"] as? [String: Any],
              let gpuUsage = gpuDict["gpu_active_residency"] as? Double
        else { return nil }

        let aneUsage = (dict["ANE"] as? [String: Any])?["ane_active_residency"] as? Double

        // Temperature: try both key variants seen in the wild
        let temperature: Double? = (gpuDict["GPU Die Temp"] as? Double)
            ?? (gpuDict["gpu_die_temperature"] as? Double)

        // Power: powermetrics reports mW in "gpu_power_mW" or W in "gpu_power"/"GPU Power"
        let rawPower: Double? = (gpuDict["gpu_power_mW"] as? Double).map { $0 / 1000.0 }
            ?? (gpuDict["gpu_power"] as? Double)
            ?? (gpuDict["GPU Power"] as? Double)

        return GPUSample(
            timestamp: timestamp,
            gpuUsage: min(max(gpuUsage, 0.0), 1.0),
            temperature: temperature,
            power: rawPower,
            aneUsage: aneUsage.map { min(max($0, 0.0), 1.0) }
        )
    }
}
