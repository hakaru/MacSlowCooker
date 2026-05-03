import Foundation
struct GPUSample: Codable, Sendable {
    let timestamp: Date
    let gpuUsage: Double?            // 0-1 range, nil if GPU metrics unavailable
    let temperature: Double?         // °C from IOHID sensors (nil if unavailable)
    let thermalPressure: String?     // "Nominal" | "Fair" | "Serious" | "Critical"
    let power: Double?               // GPU power in W
    let anePower: Double?            // ANE power in W (nil on Intel)
    let aneUsage: Double?            // legacy field, may be nil on macOS 26
}
