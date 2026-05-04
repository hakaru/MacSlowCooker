import SwiftUI

enum HistoryMetric: String, CaseIterable, Identifiable {
    case gpu, temp, power, fan
    var id: String { rawValue }

    var label: String {
        switch self {
        case .gpu: return "GPU %"
        case .temp: return "SoC Temp °C"
        case .power: return "Power W"
        case .fan: return "Fan RPM"
        }
    }

    /// Suggested fixed Y-axis upper bound; if nil, auto-scale.
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

struct MRTGGraphView: View {
    let records: [HistoryRecord]
    let metric: HistoryMetric
    let granularity: HistoryGranularity
    let nowTs: Int

    private var rangeStart: Int { nowTs - granularity.retentionSeconds }
    private var rangeEnd: Int   { nowTs }

    private var yMax: Double {
        if let hint = metric.yMaxHint { return hint }
        let vs = records.compactMap(metric.value)
        return max((vs.max() ?? 1) * 1.1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(metric.label) — \(rangeLabel)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer()
                if let last = records.last.flatMap(metric.value) {
                    Text(String(format: "now: %.1f", last))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Canvas { ctx, size in
                drawGrid(ctx, size: size)
                drawSeries(ctx, size: size)
            }
            .frame(height: 90)
            .background(Color(white: 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var rangeLabel: String {
        switch granularity {
        case .fiveMin:   return "Last 24 h"
        case .thirtyMin: return "Last 7 d"
        case .twoHour:   return "Last 31 d"
        case .oneDay:    return "Last 400 d"
        }
    }

    private func x(forTs ts: Int, in size: CGSize) -> CGFloat {
        let span = max(rangeEnd - rangeStart, 1)
        return CGFloat(ts - rangeStart) / CGFloat(span) * size.width
    }

    private func y(forValue v: Double, in size: CGSize) -> CGFloat {
        size.height - CGFloat(min(v, yMax) / yMax) * size.height
    }

    private func drawGrid(_ ctx: GraphicsContext, size: CGSize) {
        let lineColor = Color(white: 0.2)
        for i in 1..<5 {
            let yy = size.height * CGFloat(i) / 5
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yy))
            path.addLine(to: CGPoint(x: size.width, y: yy))
            ctx.stroke(path, with: .color(lineColor), lineWidth: 0.5)
        }
    }

    private func drawSeries(_ ctx: GraphicsContext, size: CGSize) {
        let pts: [(CGFloat, CGFloat)] = records.compactMap { r in
            guard let v = metric.value(r) else { return nil }
            return (x(forTs: r.ts, in: size), y(forValue: v, in: size))
        }
        guard !pts.isEmpty else { return }

        // filled area
        var area = Path()
        area.move(to: CGPoint(x: pts[0].0, y: size.height))
        for p in pts { area.addLine(to: CGPoint(x: p.0, y: p.1)) }
        area.addLine(to: CGPoint(x: pts.last!.0, y: size.height))
        area.closeSubpath()
        ctx.fill(area, with: .color(.green.opacity(0.35)))

        // line on top
        var line = Path()
        line.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for p in pts.dropFirst() { line.addLine(to: CGPoint(x: p.0, y: p.1)) }
        ctx.stroke(line, with: .color(.green), lineWidth: 1.0)
    }
}
