import Foundation

enum PowerMetricsParser {
    /// Parse one plist sample from powermetrics into a GPUSample.
    /// Supports three schema generations:
    ///   - legacy (capitalized "GPU", `gpu_active_residency`, `gpu_power_mW`)
    ///   - macOS 14+/26 (lowercase "gpu", `idle_ratio`, `gpu_energy`)
    ///   - Intel (`gpu_busy`, `busy_ns` + `elapsed_ns`)
    static func parse(plistData: Data, timestamp: Date) -> GPUSample? {
        guard let dict = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }

        // GPU dict — try both casings
        let gpuDict = (dict["gpu"] as? [String: Any]) ?? (dict["GPU"] as? [String: Any])

        // GPU usage: try the schemas in priority order, mapping each to [0, 1].
        let gpuUsage: Double? =
            coalesceDouble(from: gpuDict, keys: ["gpu_active_residency"])
            ?? coalesceDouble(from: gpuDict, keys: ["idle_ratio"]).map { max(0.0, 1.0 - $0) }
            ?? coalesceDouble(from: gpuDict, keys: ["gpu_busy"]).map { $0 / 100.0 }
            ?? busyNsRatio(in: gpuDict, topLevel: dict)

        guard let usage = gpuUsage else { return nil }

        // Temperature: legacy keys only — not exposed in macOS 26 plist output.
        let temperature = coalesceDouble(from: gpuDict, keys: ["GPU Die Temp", "gpu_die_temperature"])

        // GPU power: legacy mW first (legacy_mW / 1000 → W), legacy W keys, then
        // derive from gpu_energy (mJ) / elapsed_ns (ns) on macOS 26.
        let power = coalesceDouble(from: gpuDict, keys: ["gpu_power_mW"]).map { $0 / 1000.0 }
            ?? coalesceDouble(from: gpuDict, keys: ["gpu_power", "GPU Power"])
            ?? energyToWatts(energyMJ: coalesceDouble(from: gpuDict, keys: ["gpu_energy"]),
                             elapsedNs: dict["elapsed_ns"] as? Double)

        // ANE usage (legacy on macOS 14, nil on macOS 26).
        let aneDict = (dict["ane"] as? [String: Any]) ?? (dict["ANE"] as? [String: Any])
        let aneUsage = coalesceDouble(from: aneDict, keys: ["ane_active_residency"])
            ?? coalesceDouble(from: aneDict, keys: ["idle_ratio"]).map { max(0.0, 1.0 - $0) }

        // ANE power: macOS 26 puts it under processor.ane_power in mW.
        let processorDict = dict["processor"] as? [String: Any]
        let anePower = coalesceDouble(from: processorDict, keys: ["ane_power"]).map { $0 / 1000.0 }
            ?? energyToWatts(energyMJ: coalesceDouble(from: aneDict, keys: ["ane_energy"]),
                             elapsedNs: dict["elapsed_ns"] as? Double)

        // Thermal pressure: top-level categorical value. Use the lenient
        // initializer so case differences and trailing whitespace don't
        // silently disable the combined boiling trigger; truly unknown
        // future values (Apple may add states) still surface as nil.
        let thermalPressure = (dict["thermal_pressure"] as? String)
            .flatMap(ThermalPressure.init(lenientRawValue:))

        return GPUSample(
            timestamp: timestamp,
            gpuUsage: min(max(usage, 0.0), 1.0),
            temperature: temperature,
            thermalPressure: thermalPressure,
            power: power,
            anePower: anePower,
            aneUsage: aneUsage.map { min(max($0, 0.0), 1.0) },
            fanRPM: nil   // augmented by HelperTool's SMCReader before XPC delivery
        )
    }

    /// Try each key in order and return the first one that decodes as a
    /// `Double` (or as an `NSNumber` that we can convert to one).
    private static func coalesceDouble(from dict: [String: Any]?, keys: [String]) -> Double? {
        guard let dict else { return nil }
        for key in keys {
            if let v = dict[key] as? Double { return v }
            if let n = dict[key] as? NSNumber { return n.doubleValue }
        }
        return nil
    }

    /// busy_ns lives inside the gpu dict (Intel discrete GPU schema) but the
    /// elapsed_ns it should be divided by may live alongside it or at the
    /// plist's top level depending on macOS / GPU vendor.
    private static func busyNsRatio(in gpuDict: [String: Any]?, topLevel: [String: Any]) -> Double? {
        guard let busyNs = coalesceDouble(from: gpuDict, keys: ["busy_ns"]) else { return nil }
        let elapsed = coalesceDouble(from: gpuDict, keys: ["elapsed_ns"])
            ?? (topLevel["elapsed_ns"] as? Double)
        guard let elapsedNs = elapsed, elapsedNs > 0 else { return nil }
        return busyNs / elapsedNs
    }

    /// Convert energy (mJ) over an elapsed window (ns) into average watts.
    private static func energyToWatts(energyMJ: Double?, elapsedNs: Double?) -> Double? {
        guard let energyMJ, let elapsedNs, elapsedNs > 0 else { return nil }
        return (energyMJ / 1000.0) / (elapsedNs / 1_000_000_000.0)
    }
}
