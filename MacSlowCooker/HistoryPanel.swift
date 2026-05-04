import Foundation

enum HistoryMetric: String, CaseIterable, Identifiable {
    case gpu, temp, power, fan
    var id: String { rawValue }

    var label: String {
        switch self {
        case .gpu: return "GPU"
        case .temp: return "Temp"
        case .power: return "Power"
        case .fan: return "Fan"
        }
    }

    var unit: String {
        switch self {
        case .gpu: return "%"
        case .temp: return "°C"
        case .power: return "W"
        case .fan: return "rpm"
        }
    }

    var yMaxHint: Double? {
        switch self {
        case .gpu: return 100
        case .temp: return 110
        case .power: return nil
        case .fan: return nil
        }
    }

    func value(_ r: HistoryRecord) -> Double? {
        switch self {
        case .gpu:   return r.gpuPct
        case .temp:  return r.socTempC
        case .power: return r.powerW
        case .fan:   return r.fanRPM
        }
    }
}

/// A two-series MRTG-style panel: a filled "primary" series and a
/// line-overlay "secondary" series, each on its own Y axis.
struct HistoryPanel: Identifiable, Hashable {
    let id: String
    let title: String
    let primary: HistoryMetric    // filled green
    let secondary: HistoryMetric  // blue line

    static let compute = HistoryPanel(id: "compute", title: "Compute", primary: .gpu,  secondary: .power)
    static let thermal = HistoryPanel(id: "thermal", title: "Thermal", primary: .temp, secondary: .fan)

    static let all: [HistoryPanel] = [.compute, .thermal]
}
