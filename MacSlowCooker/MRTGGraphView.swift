import SwiftUI

private enum MRTGStyle {
    static let background      = Color.white
    static let primaryFill     = Color(red: 0.0,  green: 0.80, blue: 0.0)    // MRTG green #00cc00
    static let primaryLine     = Color(red: 0.0,  green: 0.40, blue: 0.0)    // darker green
    static let primaryAxisText = Color(red: 0.0,  green: 0.40, blue: 0.0)
    static let secondaryLine   = Color(red: 0.0,  green: 0.0,  blue: 0.80)   // MRTG blue
    static let secondaryAxisText = Color(red: 0.0, green: 0.0, blue: 0.80)
    static let gridFine        = Color(white: 0.88)
    static let gridCoarse      = Color(white: 0.55)
    static let axisText        = Color.black
    static let titleBar        = Color(red: 0.32, green: 0.36, blue: 0.55)   // dark navy
    static let titleText       = Color.white
    static let footerBg        = Color.white
    static let frame           = Color.black
}

struct MRTGGraphView: View {
    let records: [HistoryRecord]
    let panel: HistoryPanel
    let granularity: HistoryGranularity
    let nowTs: Int

    private var rangeStart: Int { nowTs - granularity.retentionSeconds }
    private var rangeEnd: Int   { nowTs }

    private var primaryValues:   [Double] { records.compactMap(panel.primary.value) }
    private var secondaryValues: [Double] { records.compactMap(panel.secondary.value) }

    private var yMaxPrimary: Double {
        if let h = panel.primary.yMaxHint { return h }
        return Swift.max((primaryValues.max() ?? 1) * 1.1, 1)
    }

    private var yMaxSecondary: Double {
        if let h = panel.secondary.yMaxHint { return h }
        return Swift.max((secondaryValues.max() ?? 1) * 1.1, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            HStack(spacing: 0) {
                yAxisLabels(yMax: yMaxPrimary,
                            unit: panel.primary.unit,
                            color: MRTGStyle.primaryAxisText,
                            alignment: .trailing)
                canvas
                yAxisLabels(yMax: yMaxSecondary,
                            unit: panel.secondary.unit,
                            color: MRTGStyle.secondaryAxisText,
                            alignment: .leading)
            }
            .padding(.top, 10)   // breathing room above the topmost gridline
            xAxisLabels
            statsFooter
        }
        .background(MRTGStyle.background)
        .overlay(Rectangle().stroke(MRTGStyle.frame, lineWidth: 0.5))
    }

    // MARK: - Subviews

    private var titleBar: some View {
        Text("\(rangeLabel) — \(panel.title)")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(MRTGStyle.titleText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
            .background(MRTGStyle.titleBar)
    }

    private func yAxisLabels(yMax: Double, unit: String, color: Color, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(formatY(yMax, unit: unit))
            Spacer(minLength: 0)
            Text(formatY(yMax * 0.75, unit: unit))
            Spacer(minLength: 0)
            Text(formatY(yMax * 0.5, unit: unit))
            Spacer(minLength: 0)
            Text(formatY(yMax * 0.25, unit: unit))
            Spacer(minLength: 0)
            Text(formatY(0, unit: unit))
        }
        .font(.custom("Menlo", size: 10))
        .foregroundColor(color)
        .frame(width: yAxisWidth, height: graphHeight)
        .padding(alignment == .trailing ? .trailing : .leading, 3)
    }

    private var canvas: some View {
        Canvas { ctx, size in
            drawGrid(ctx, size: size)
            drawSeries(ctx, size: size)
        }
        .frame(height: graphHeight)
        .overlay(Rectangle().stroke(MRTGStyle.frame, lineWidth: 0.5))
    }

    /// Place a label at every Nth fine vertical gridline so labels align with
    /// real grid positions instead of an evenly-spaced HStack.
    private var xLabelEveryFineLine: Int {
        switch granularity {
        case .fiveMin:   return 2   // every 2h (fine = 1h)         → 13 labels
        case .thirtyMin: return 4   // every 1d (fine = 6h)         → 8 labels
        case .twoHour:   return 5   // every 5d (fine = 1d)         → 7 labels
        case .oneDay:    return 8   // every ~56d (fine = 1w)       → 8 labels
        }
    }

    private func xLabelPositions() -> [(frac: Double, label: String)] {
        let spec = verticalGridSpec
        let total = granularity.retentionSeconds
        let count = total / spec.fine
        var out: [(Double, String)] = []
        for i in stride(from: 0, through: count, by: xLabelEveryFineLine) {
            let secAgo = i * spec.fine
            let frac = 1.0 - Double(secAgo) / Double(total)
            out.append((frac, xLabel(at: frac)))
        }
        return out
    }

    private var xAxisLabels: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: yAxisWidth + 2)
            Canvas { ctx, size in
                for (frac, label) in xLabelPositions() {
                    let xx = CGFloat(frac) * size.width
                    let resolved = ctx.resolve(
                        Text(label)
                            .font(.custom("Menlo", size: 10))
                            .foregroundColor(MRTGStyle.axisText)
                    )
                    let anchor: UnitPoint
                    if frac < 0.02       { anchor = .topLeading }
                    else if frac > 0.98  { anchor = .topTrailing }
                    else                 { anchor = .top }
                    ctx.draw(resolved, at: CGPoint(x: xx, y: 0), anchor: anchor)
                }
            }
            .frame(height: 14)
            Spacer().frame(width: yAxisWidth + 2)
        }
        .padding(.vertical, 2)
    }

    private var statsFooter: some View {
        VStack(spacing: 1) {
            statsRow(metric: panel.primary,   values: primaryValues,   colorBox: MRTGStyle.primaryFill)
            statsRow(metric: panel.secondary, values: secondaryValues, colorBox: MRTGStyle.secondaryLine)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(MRTGStyle.footerBg)
        .overlay(
            Rectangle().frame(height: 0.5).foregroundColor(MRTGStyle.frame),
            alignment: .top
        )
    }

    private func statsRow(metric: HistoryMetric, values: [Double], colorBox: Color) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(colorBox)
                .frame(width: 10, height: 10)
                .overlay(Rectangle().stroke(Color.black.opacity(0.3), lineWidth: 0.5))
            Text(metric.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(width: 56, alignment: .leading)
            stat("Max", values.max(), unit: metric.unit)
            Spacer()
            stat("Avg", values.isEmpty ? nil : values.reduce(0, +) / Double(values.count), unit: metric.unit)
            Spacer()
            stat("Cur", values.last, unit: metric.unit)
        }
        .foregroundColor(.black)
    }

    private func stat(_ label: String, _ value: Double?, unit: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Color(white: 0.35))
            Text(value.map { "\(formatStat($0)) \(unit)" } ?? "—")
                .font(.custom("Menlo", size: 11))
        }
    }

    // MARK: - Layout

    private var graphHeight: CGFloat { 90 }
    private var yAxisWidth: CGFloat { 52 }   // wide enough for "5000rpm" / "1.5kW"

    // MARK: - Formatting

    private func formatY(_ v: Double, unit: String) -> String {
        let n: String
        if v >= 10000      { n = String(format: "%.0fk", v / 1000) }
        else if v >= 1000  { n = String(format: "%.1fk", v / 1000) }
        else if v >= 10    { n = String(format: "%.0f", v) }
        else if v == 0     { n = "0" }
        else               { n = String(format: "%.1f", v) }
        // Tight join (no space) for narrow Y axis column.
        return "\(n)\(unit)"
    }

    private func formatStat(_ v: Double) -> String {
        if v >= 1000     { return String(format: "%.0f", v) }
        if v >= 10       { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    private var rangeLabel: String {
        switch granularity {
        case .fiveMin:   return "Daily Graph (5 Minute Average)"
        case .thirtyMin: return "Weekly Graph (30 Minute Average)"
        case .twoHour:   return "Monthly Graph (2 Hour Average)"
        case .oneDay:    return "Yearly Graph (1 Day Average)"
        }
    }

    private static let dayOfWeekFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM"
        return f
    }()

    private func xLabel(at frac: Double) -> String {
        let ts = TimeInterval(rangeStart) + frac * Double(granularity.retentionSeconds)
        let date = Date(timeIntervalSince1970: ts)
        let cal = Calendar.current
        switch granularity {
        case .fiveMin:
            return String(format: "%02d", cal.component(.hour, from: date))
        case .thirtyMin:
            return Self.dayOfWeekFormatter.string(from: date)
        case .twoHour:
            return "\(cal.component(.day, from: date))"
        case .oneDay:
            return Self.monthFormatter.string(from: date)
        }
    }

    // MARK: - Canvas geometry

    private func x(forTs ts: Int, in size: CGSize) -> CGFloat {
        let span = max(rangeEnd - rangeStart, 1)
        return CGFloat(ts - rangeStart) / CGFloat(span) * size.width
    }

    private func y(_ v: Double, max yMax: Double, in size: CGSize) -> CGFloat {
        let clamped = Swift.max(0, Swift.min(v, yMax))
        return size.height - CGFloat(clamped / yMax) * size.height
    }

    /// (fineIntervalSec, every-Nth-line-is-coarse).
    private var verticalGridSpec: (fine: Int, coarseEvery: Int) {
        switch granularity {
        case .fiveMin:   return (3600,    4)   // every 1h, coarse every 4h
        case .thirtyMin: return (21600,   4)   // every 6h, coarse every 24h (1d)
        case .twoHour:   return (86400,   5)   // every 1d, coarse every 5d
        case .oneDay:    return (604800,  4)   // every 1w, coarse every ~month
        }
    }

    private func drawGrid(_ ctx: GraphicsContext, size: CGSize) {
        // Horizontal: 4 fine + 1 coarse at the bottom baseline
        for i in 0...4 {
            let yy = size.height * CGFloat(i) / 4
            var p = Path()
            p.move(to: CGPoint(x: 0, y: yy))
            p.addLine(to: CGPoint(x: size.width, y: yy))
            let isCoarse = (i == 0 || i == 4)
            ctx.stroke(p, with: .color(isCoarse ? MRTGStyle.gridCoarse : MRTGStyle.gridFine), lineWidth: 0.5)
        }

        // Vertical: tick every `fine` seconds, coarse every Nth.
        let spec = verticalGridSpec
        let total = granularity.retentionSeconds
        let count = total / spec.fine
        // Pass 1: fine lines
        for i in 0...count where i % spec.coarseEvery != 0 {
            let secAgo = i * spec.fine
            let frac = 1.0 - Double(secAgo) / Double(total)
            let xx = CGFloat(frac) * size.width
            var p = Path()
            p.move(to: CGPoint(x: xx, y: 0))
            p.addLine(to: CGPoint(x: xx, y: size.height))
            ctx.stroke(p, with: .color(MRTGStyle.gridFine), lineWidth: 0.5)
        }
        // Pass 2: coarse lines on top
        for i in stride(from: 0, through: count, by: spec.coarseEvery) {
            let secAgo = i * spec.fine
            let frac = 1.0 - Double(secAgo) / Double(total)
            let xx = CGFloat(frac) * size.width
            var p = Path()
            p.move(to: CGPoint(x: xx, y: 0))
            p.addLine(to: CGPoint(x: xx, y: size.height))
            ctx.stroke(p, with: .color(MRTGStyle.gridCoarse), lineWidth: 0.5)
        }
    }

    private func drawSeries(_ ctx: GraphicsContext, size: CGSize) {
        // Primary: filled green area + dark green line
        let primaryPts: [(CGFloat, CGFloat)] = records.compactMap { r in
            guard let v = panel.primary.value(r) else { return nil }
            return (x(forTs: r.ts, in: size), y(v, max: yMaxPrimary, in: size))
        }
        if !primaryPts.isEmpty {
            var area = Path()
            area.move(to: CGPoint(x: primaryPts[0].0, y: size.height))
            for p in primaryPts { area.addLine(to: CGPoint(x: p.0, y: p.1)) }
            area.addLine(to: CGPoint(x: primaryPts.last!.0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(MRTGStyle.primaryFill))

            var line = Path()
            line.move(to: CGPoint(x: primaryPts[0].0, y: primaryPts[0].1))
            for p in primaryPts.dropFirst() { line.addLine(to: CGPoint(x: p.0, y: p.1)) }
            ctx.stroke(line, with: .color(MRTGStyle.primaryLine), lineWidth: 1.0)
        }

        // Secondary: blue line on its own scale
        let secondaryPts: [(CGFloat, CGFloat)] = records.compactMap { r in
            guard let v = panel.secondary.value(r) else { return nil }
            return (x(forTs: r.ts, in: size), y(v, max: yMaxSecondary, in: size))
        }
        if !secondaryPts.isEmpty {
            var line = Path()
            line.move(to: CGPoint(x: secondaryPts[0].0, y: secondaryPts[0].1))
            for p in secondaryPts.dropFirst() { line.addLine(to: CGPoint(x: p.0, y: p.1)) }
            ctx.stroke(line, with: .color(MRTGStyle.secondaryLine), lineWidth: 1.2)
        }
    }

}
