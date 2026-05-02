import AppKit
import Foundation

// MARK: - Settings enums

enum PotStyle: String, CaseIterable, Codable {
    case dutchOven = "dutchOven"
    // 将来: case oden, curry, saucepan
}

enum FlameAnimation: String, CaseIterable, Codable {
    case none           = "none"
    case interpolation  = "interpolation"
    case wiggle         = "wiggle"
    case both           = "both"

    var hasInterpolation: Bool { self == .interpolation || self == .both }
    var hasWiggle: Bool        { self == .wiggle        || self == .both }
}

enum BoilingTrigger: String, CaseIterable, Codable {
    case temperature       = "temperature"
    case thermalPressure   = "thermalPressure"
    case combined          = "combined"
}

// MARK: - Renderer input

struct IconState: Equatable {
    let displayedUsage: Double      // [0, 1] interpolated value
    let temperature: Double?        // °C, nil if unavailable
    let isConnected: Bool

    let flameWigglePhase: Double    // [0, 2π) — ignored when wiggle disabled
    let flameWiggleEnabled: Bool

    let isBoiling: Bool
    let boilingIntensity: Double    // [0, 1] faded value
}

extension IconState {
    /// Quantized hash used to skip redundant Dock icon updates.
    /// Two states with the same `visualHash` produce visually indistinguishable bitmaps.
    var visualHash: Int {
        var hasher = Hasher()
        hasher.combine(isConnected)
        hasher.combine(flameWiggleEnabled)
        hasher.combine(isBoiling)
        hasher.combine(Int((displayedUsage * 200.0).rounded()))    // 0.005 step
        hasher.combine(Int((boilingIntensity * 100.0).rounded())) // 0.01 step
        if flameWiggleEnabled {
            hasher.combine(Int((flameWigglePhase * 20.0).rounded())) // 0.05 rad step
        }
        return hasher.finalize()
    }
}

// MARK: - Renderer protocol

protocol PotRenderer {
    static var iconSize: CGSize { get }
    static func render(state: IconState) -> NSImage
}

extension PotRenderer {
    static var iconSize: CGSize { CGSize(width: 512, height: 512) }
}
