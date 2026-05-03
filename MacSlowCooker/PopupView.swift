import SwiftUI
import Charts

struct PopupView: View {
    let store: GPUDataStore

    var body: some View {
        // Vertical layout: fixed-height header, flexible chart row, fixed metric tiles.
        // Resizing only stretches the chart area; the header and bottom margins
        // never change size.
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(height: 46)                  // fixed top band
            charts
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)        // grows with window resize
            metrics
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .frame(height: 102)                 // fixed bottom band
        }
        .frame(minWidth: 760, minHeight: 320)
        .background(VisualEffectBackground())
        .preferredColorScheme(.dark)
    }

    // MARK: - Header (fixed height)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "flame.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange.gradient)
            Text(chipName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(store.isConnected ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(store.isConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 22)
    }

    // MARK: - Charts (grow with window)

    private var charts: some View {
        HStack(spacing: 10) {
            chartView(
                title: "GPU",
                systemImage: "cpu.fill",
                samples: store.samples,
                value: { sample -> Double? in sample.gpuUsage },
                color: .cyan,
                scale: 100,
                yDomain: 0...100,
                unit: "%"
            )
            chartView(
                title: "Temperature",
                systemImage: "thermometer.medium",
                samples: store.samples,
                value: { $0.temperature },
                color: .orange,
                scale: 1,
                yDomain: 30...100,
                unit: "°C"
            )
            chartView(
                title: "Fan",
                systemImage: "fan.fill",
                samples: store.samples,
                value: { $0.fanRPM?.max() },
                color: .mint,
                scale: 1,
                yDomain: 0...4000,
                unit: "rpm"
            )
            chartView(
                title: "Power",
                systemImage: "bolt.fill",
                samples: store.samples,
                value: { $0.power },
                color: .yellow,
                scale: 1,
                yDomain: 0...150,
                unit: "W"
            )
        }
    }

    private func chartView(
        title: String,
        systemImage: String,
        samples: [GPUSample],
        value: @escaping (GPUSample) -> Double?,
        color: Color,
        scale: Double,
        yDomain: ClosedRange<Double>,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                Spacer()
                Text("\(Int(yDomain.lowerBound))–\(Int(yDomain.upperBound))\(unit)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Chart {
                ForEach(samples.indices, id: \.self) { i in
                    chartMarks(at: i, value: value(samples[i]), scale: scale, color: color)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: yDomain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.10))           // subtle color tint, brighter
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
            )
            .opacity(store.isConnected ? 1.0 : 0.4)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    @ChartContentBuilder
    private func chartMarks(at i: Int, value: Double?, scale: Double, color: Color) -> some ChartContent {
        if let v = value {
            AreaMark(x: .value("t", i), y: .value("v", v * scale))
                .foregroundStyle(color.opacity(0.30).gradient)
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", i), y: .value("v", v * scale))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .interpolationMethod(.monotone)
        }
    }

    // MARK: - Metric tiles (fixed height)

    private var metrics: some View {
        HStack(spacing: 10) {
            metricCard(systemImage: "cpu.fill",            label: "GPU",
                       value: gpuText,   accent: .cyan,    valueColor: gpuDangerColor)
            metricCard(systemImage: "thermometer.medium",  label: "Temp",
                       value: tempText,  accent: tempColor, valueColor: tempDangerColor)
            metricCard(systemImage: "fan.fill",            label: "Fan",
                       value: fanText,   accent: .mint,    valueColor: fanDangerColor)
            metricCard(systemImage: "bolt.fill",           label: "Power",
                       value: powerText, accent: .yellow,  valueColor: powerDangerColor)
        }
    }

    private func metricCard(systemImage: String, label: String, value: String,
                            accent: Color, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(accent)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(accent.opacity(0.35), lineWidth: 1)
                )
        )
    }

    // MARK: - Danger color thresholds
    // Each metric returns:
    //   .primary (white) for safe, .yellow for elevated, .red for critical.

    private var gpuDangerColor: Color {
        guard let u = latest?.gpuUsage else { return .primary }
        switch u {
        case ..<0.6:  return .primary
        case ..<0.85: return .yellow
        default:      return .red
        }
    }

    private var tempDangerColor: Color {
        if let t = latest?.temperature {
            switch t {
            case ..<70:  return .primary
            case ..<85:  return .yellow
            default:     return .red
            }
        }
        switch latest?.thermalPressure {
        case "Serious":  return .yellow
        case "Critical": return .red
        default:         return .primary
        }
    }

    private var fanDangerColor: Color {
        guard let fans = latest?.fanRPM, !fans.isEmpty else { return .primary }
        let avg = fans.reduce(0, +) / Double(fans.count)
        switch avg {
        case ..<2500:  return .primary
        case ..<3500:  return .yellow
        default:       return .red
        }
    }

    private var powerDangerColor: Color {
        guard let p = latest?.power else { return .primary }
        switch p {
        case ..<60:   return .primary
        case ..<100:  return .yellow
        default:      return .red
        }
    }

    // MARK: - Derived values

    /// Apple Silicon chip name, e.g., "Apple M3 Ultra".
    private var chipName: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    private var latest: GPUSample? { store.latestSample }

    private var gpuText: String {
        latest.map { String(format: "%.0f%%", $0.gpuUsage * 100) } ?? "--"
    }

    private var tempText: String {
        if let t = latest?.temperature {
            return String(format: "%.0f°C", t)
        }
        return latest?.thermalPressure ?? "--"
    }

    private var tempColor: Color {
        if let t = latest?.temperature {
            switch t {
            case ..<60:  return .green
            case ..<75:  return .yellow
            case ..<85:  return .orange
            default:     return .red
            }
        }
        switch latest?.thermalPressure {
        case "Nominal":  return .green
        case "Fair":     return .yellow
        case "Serious":  return .orange
        case "Critical": return .red
        default:         return .orange
        }
    }

    private var fanText: String {
        guard let fans = latest?.fanRPM, !fans.isEmpty else { return "--" }
        let avg = fans.reduce(0, +) / Double(fans.count)
        return String(format: "%.0f rpm", avg)
    }

    private var powerText: String {
        latest?.power.map { String(format: "%.1f W", $0) } ?? "--"
    }
}

// MARK: - Translucent window background

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
