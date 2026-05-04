import Foundation

/// Pure renderer for Prometheus text exposition format (version 0.0.4).
/// Reference: https://prometheus.io/docs/instrumenting/exposition_formats/
enum PrometheusFormatter {
    /// Render the current snapshot to an exposition string. Missing values
    /// (e.g. fanless Macs, no power data, helper down) cause those metric
    /// lines to be omitted entirely — Prometheus prefers absence over fake
    /// zeros for "unknown".
    static func exposition(sample: GPUSample?, helperConnected: Bool, version: String) -> String {
        var out = ""

        // build_info — always emitted, identifies this binary.
        out += "# HELP macslowcooker_build_info Build metadata as a constant 1.\n"
        out += "# TYPE macslowcooker_build_info gauge\n"
        out += "macslowcooker_build_info{version=\"\(version)\"} 1\n"

        // helper_connected — always emitted (0 or 1).
        out += "# HELP macslowcooker_helper_connected Whether the privileged HelperTool XPC connection is up (0 or 1).\n"
        out += "# TYPE macslowcooker_helper_connected gauge\n"
        out += "macslowcooker_helper_connected \(helperConnected ? 1 : 0)\n"

        guard let s = sample else { return out }

        // gpu_usage_ratio (0..1).
        out += "# HELP macslowcooker_gpu_usage_ratio GPU usage as a 0..1 ratio (1 - idle_ratio from powermetrics).\n"
        out += "# TYPE macslowcooker_gpu_usage_ratio gauge\n"
        out += "macslowcooker_gpu_usage_ratio \(format(s.gpuUsage))\n"

        if let p = s.power {
            out += "# HELP macslowcooker_gpu_power_watts Current GPU power draw in watts.\n"
            out += "# TYPE macslowcooker_gpu_power_watts gauge\n"
            out += "macslowcooker_gpu_power_watts \(format(p))\n"
        }

        if let a = s.anePower {
            out += "# HELP macslowcooker_ane_power_watts Current Apple Neural Engine power draw in watts.\n"
            out += "# TYPE macslowcooker_ane_power_watts gauge\n"
            out += "macslowcooker_ane_power_watts \(format(a))\n"
        }

        if let t = s.temperature {
            out += "# HELP macslowcooker_temperature_celsius SoC temperature in degrees Celsius (averaged across die / proximity sensors).\n"
            out += "# TYPE macslowcooker_temperature_celsius gauge\n"
            out += "macslowcooker_temperature_celsius \(format(t))\n"
        }

        if let tp = s.thermalPressure {
            out += "# HELP macslowcooker_thermal_pressure Thermal pressure level (0=Nominal, 1=Fair, 2=Serious, 3=Critical).\n"
            out += "# TYPE macslowcooker_thermal_pressure gauge\n"
            out += "macslowcooker_thermal_pressure \(level(of: tp))\n"
        }

        if let fans = s.fanRPM, !fans.isEmpty {
            out += "# HELP macslowcooker_fan_rpm Fan rotation speed in RPM, labelled by fan index.\n"
            out += "# TYPE macslowcooker_fan_rpm gauge\n"
            for (i, rpm) in fans.enumerated() {
                out += "macslowcooker_fan_rpm{fan=\"\(i)\"} \(format(rpm))\n"
            }
        }

        return out
    }

    /// Trim trailing zeros and decimal point. Prometheus accepts plain numeric
    /// floats; minimising width keeps the response small.
    private static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return String(format: "%g", v)
        }
        return String(format: "%g", v)
    }

    private static func level(of pressure: ThermalPressure) -> Int {
        switch pressure {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        }
    }
}
