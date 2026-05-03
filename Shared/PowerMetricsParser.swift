import Foundation

enum PowerMetricsParser {
    static func parse(plistData: Data, timestamp: Date) -> GPUSample? {
        guard let dict = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }

        let gpuDict = (dict["gpu"] as? [String: Any]) ?? (dict["GPU"] as? [String: Any])

        var gpuUsage: Double?
        if let gpu = gpuDict {
            if let active = gpu["gpu_active_residency"] as? Double {
                gpuUsage = active
            } else if let idle = gpu["idle_ratio"] as? Double {
                gpuUsage = max(0.0, 1.0 - idle)
            } else if let busy = gpu["gpu_busy"] as? Double {
                gpuUsage = busy / 100.0
            } else if let busyNs = gpu["busy_ns"] as? Double,
                      let elapsedNs = (gpu["elapsed_ns"] as? Double) ?? (dict["elapsed_ns"] as? Double),
                      elapsedNs > 0 {
                gpuUsage = busyNs / elapsedNs
            }
        }

        let temperature: Double? = (gpuDict?["GPU Die Temp"] as? Double)
            ?? (gpuDict?["gpu_die_temperature"] as? Double)

        var power: Double?
        if let p = (gpuDict?["gpu_power_mW"] as? Double).map({ $0 / 1000.0 })
            ?? (gpuDict?["gpu_power"] as? Double)
            ?? (gpuDict?["GPU Power"] as? Double) {
            power = p
        } else if let energyMJ = gpuDict?["gpu_energy"] as? Double,
                  let elapsedNs = dict["elapsed_ns"] as? Double, elapsedNs > 0 {
            power = (energyMJ / 1000.0) / (elapsedNs / 1_000_000_000.0)
        }

        let aneDict = (dict["ane"] as? [String: Any]) ?? (dict["ANE"] as? [String: Any])
        let aneUsage: Double? = (aneDict?["ane_active_residency"] as? Double)
            ?? (aneDict?["idle_ratio"] as? Double).map { max(0.0, 1.0 - $0) }

        var anePower: Double?
        if let processor = dict["processor"] as? [String: Any],
           let aneMW = processor["ane_power"] as? Double {
            anePower = aneMW / 1000.0
        } else if let energyMJ = (aneDict?["ane_energy"] as? Double),
                  let elapsedNs = dict["elapsed_ns"] as? Double, elapsedNs > 0 {
            anePower = (energyMJ / 1000.0) / (elapsedNs / 1_000_000_000.0)
        }

        let thermalPressure = dict["thermal_pressure"] as? String

        // GPU データも温度も電力も取れない場合は無効サンプル
        if gpuUsage == nil && temperature == nil && power == nil && thermalPressure == nil {
            return nil
        }

        return GPUSample(
            timestamp: timestamp,
            gpuUsage: gpuUsage.map { min(max($0, 0.0), 1.0) },
            temperature: temperature,
            thermalPressure: thermalPressure,
            power: power,
            anePower: anePower,
            aneUsage: aneUsage.map { min(max($0, 0.0), 1.0) }
        )
    }
}
