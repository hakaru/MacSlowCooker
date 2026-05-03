import Foundation

// MARK: - Settings enums
//
// Lives in Shared/ so the helper, the app, and tests can all reference it
// without pulling in the renderer or AppKit. Logic-layer types should
// flow downward into the view layer, not the other way around.

enum PotStyle: String, CaseIterable, Codable {
    case dutchOven = "dutchOven"
    // Future: case oden, curry, saucepan
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

/// Thermal pressure as reported by powermetrics' `thermal_pressure` key
/// and `NSProcessInfo.thermalState`. Modeled as an enum so comparisons and
/// switches are exhaustive and a typo'd string literal can't silently
/// flip the comparison to false.
enum ThermalPressure: String, CaseIterable, Codable, Sendable {
    case nominal  = "Nominal"
    case fair     = "Fair"
    case serious  = "Serious"
    case critical = "Critical"

    /// True when the OS asks us to back off — at "Serious" or "Critical".
    /// Used by the boiling-trigger heuristics.
    var isPressured: Bool { self == .serious || self == .critical }
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

    /// Representative fan speed (max across fans) in RPM. Drives steam intensity.
    /// nil on fanless machines.
    let fanRPM: Double?
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
        if let temperature {
            hasher.combine(Int(temperature.rounded()))             // 1°C step
        }
        if let fanRPM {
            hasher.combine(Int((fanRPM / 50.0).rounded()))          // 50 RPM step
        }
        return hasher.finalize()
    }
}
