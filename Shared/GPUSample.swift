import Foundation
struct GPUSample: Codable, Sendable {
    let timestamp: Date
    let gpuUsage: Double
    let temperature: Double?
    let power: Double?
    let aneUsage: Double?
}
