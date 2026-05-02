import SwiftUI
import Charts

struct PopupView: View {
    let store: GPUDataStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            charts
            metrics
        }
        .padding(16)
        .frame(width: 320, height: 280)
        .background(.black.opacity(0.92))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("GPUSMI")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Text("· \(gpuName)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Circle()
                .fill(store.isConnected ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
        }
    }

    private var charts: some View {
        HStack(spacing: 8) {
            chartView(
                title: "GPU",
                samples: store.samples,
                value: \.gpuUsage,
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
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
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
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 80)
            .opacity(store.isConnected ? 1.0 : 0.4)
        }
    }

    private var metrics: some View {
        HStack {
            metricItem(label: "GPU", value: gpuText, color: .cyan)
            metricItem(label: "Temp", value: tempText, color: .orange)
            metricItem(label: "Power", value: powerText, color: .secondary)
            metricItem(label: "ANE", value: aneText, color: .purple)
        }
    }

    private func metricItem(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var gpuName: String { "M3 Ultra" }
    private var latest: GPUSample? { store.latestSample }

    private var gpuText: String {
        latest.map { String(format: "%.0f%%", $0.gpuUsage * 100) } ?? "--"
    }
    private var tempText: String {
        latest?.temperature.map { String(format: "%.0f°C", $0) } ?? "--"
    }
    private var powerText: String {
        latest?.power.map { String(format: "%.1fW", $0) } ?? "--"
    }
    private var aneText: String {
        latest?.aneUsage.map { String(format: "%.0f%%", $0 * 100) } ?? "--"
    }
}
