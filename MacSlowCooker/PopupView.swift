import SwiftUI
import Charts

struct PopupView: View {
    let store: GPUDataStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            charts
            metrics
        }
        .padding(24)
        .frame(width: 520, height: 480)
        .background(.black.opacity(0.94))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("MacSlowCooker")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
            Text(gpuName)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text("\(store.samples.count) samples")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
            Circle()
                .fill(store.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
        }
    }

    private var charts: some View {
        HStack(spacing: 8) {
            chartView(
                title: "GPU",
                samples: store.samples,
                value: { $0.gpuUsage ?? 0 },
                color: .cyan,
                format: "%.0f%%",
                scale: 100
            )
            chartView(
                title: "Temp",
                samples: store.samples,
                value: { $0.temperature ?? 0 },
                color: .orange,
                format: "%.0f°C",
                scale: 1
            )
        }
    }

    private func chartView(
        title: String,
        samples: [GPUSample],
        value: @escaping (GPUSample) -> Double,
        color: Color,
        format: String,
        scale: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Chart(samples.indices, id: \.self) { i in
                let v = value(samples[i])
                AreaMark(
                    x: .value("t", i),
                    y: .value("v", v * scale)
                )
                .foregroundStyle(color.opacity(0.3))
                LineMark(
                    x: .value("t", i),
                    y: .value("v", v * scale)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 130)
            .opacity(store.isConnected ? 1.0 : 0.4)
        }
    }

    private var metrics: some View {
        HStack(spacing: 8) {
            metricItem(label: "GPU使用率", value: gpuText, color: .cyan)
            #if arch(arm64)
            metricItem(label: "SoC 温度", value: tempText, color: tempColor)
            #else
            metricItem(label: "温度", value: tempText, color: tempColor)
            #endif
            metricItem(label: "電力", value: powerText, color: Color(red: 0.7, green: 0.7, blue: 0.75))
            #if arch(arm64)
            metricItem(label: "ANE 電力", value: anePowerText, color: .purple)
            #endif
        }
    }

    private func metricItem(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(color.opacity(0.55))
        .cornerRadius(12)
    }

    private var gpuName: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
    private var latest: GPUSample? { store.latestSample }

    private var gpuText: String {
        latest?.gpuUsage.map { String(format: "%.0f%%", $0 * 100) } ?? "--"
    }
    private var tempText: String {
        if let t = latest?.temperature {
            return String(format: "%.0f°C", t)
        }
        // Fallback to thermal_pressure level when actual sensor temperature is unavailable
        switch latest?.thermalPressure {
        case "Nominal":  return "良好"
        case "Fair":     return "やや高"
        case "Serious":  return "高"
        case "Critical": return "危険"
        default:         return "--"
        }
    }
    private var tempColor: Color {
        if latest?.temperature != nil {
            return .orange
        }
        switch latest?.thermalPressure {
        case "Nominal":  return .green
        case "Fair":     return .yellow
        case "Serious":  return .orange
        case "Critical": return .red
        default:         return .orange
        }
    }
    private var powerText: String {
        latest?.power.map { String(format: "%.1fW", $0) } ?? "--"
    }
    private var anePowerText: String {
        latest?.anePower.map { String(format: "%.2fW", $0) } ?? "--"
    }
}
