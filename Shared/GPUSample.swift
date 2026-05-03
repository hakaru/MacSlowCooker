import Foundation
struct GPUSample: Codable, Sendable {
    let timestamp: Date
    let gpuUsage: Double
    let temperature: Double?       // °C from IOHID sensors (nil if unavailable)
    let thermalPressure: String?   // "Nominal" | "Fair" | "Serious" | "Critical"
    let power: Double?             // GPU power in W
    let anePower: Double?          // ANE power in W
    let aneUsage: Double?          // legacy field, may be nil on macOS 26
    let fanRPM: [Double]?          // Fan speeds in RPM (one per fan), nil on fanless macs
}
