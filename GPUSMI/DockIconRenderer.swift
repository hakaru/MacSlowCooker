import AppKit
import CoreGraphics

enum DockIconRenderer {

    static let iconSize = CGSize(width: 512, height: 512)

    static func render(usage: Double, isConnected: Bool) -> NSImage {
        let size = iconSize
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage(size: size) }

        let rect = CGRect(origin: .zero, size: size)
        draw(in: ctx, rect: rect, usage: usage, isConnected: isConnected)

        guard let cgImage = ctx.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cgImage, size: size)
    }

    private static func draw(in ctx: CGContext, rect: CGRect, usage: Double, isConnected: Bool) {
        let padding: CGFloat = 48
        let barWidth: CGFloat = rect.width - padding * 2
        let barHeight: CGFloat = rect.height - padding * 2
        let barX: CGFloat = padding
        let barY: CGFloat = padding

        // Background
        ctx.setFillColor(NSColor(white: 0.1, alpha: 0.85).cgColor)
        let bgPath = CGPath(roundedRect: rect, cornerWidth: 80, cornerHeight: 80, transform: nil)
        ctx.addPath(bgPath)
        ctx.fillPath()

        // Bar background track
        ctx.setFillColor(NSColor(white: 0.25, alpha: 1.0).cgColor)
        let bgBarRect = CGRect(x: barX, y: barY, width: barWidth, height: barHeight)
        let bgBarPath = CGPath(roundedRect: bgBarRect, cornerWidth: 24, cornerHeight: 24, transform: nil)
        ctx.addPath(bgBarPath)
        ctx.fillPath()

        // Bar fill (bottom-to-top proportional to usage)
        let fillHeight = barHeight * CGFloat(max(0, min(1, usage)))
        let fillRect = CGRect(x: barX, y: barY, width: barWidth, height: fillHeight)

        let barColor = isConnected ? color(for: usage) : NSColor.systemGray.cgColor
        ctx.setFillColor(barColor)

        ctx.saveGState()
        ctx.addPath(bgBarPath)
        ctx.clip()
        ctx.fill(fillRect)
        ctx.restoreGState()

        // Usage text label
        let label = isConnected ? String(format: "%.0f%%", usage * 100) : "--"
        drawLabel(ctx, text: label, in: rect, above: barY + barHeight + 8)
    }

    private static func color(for usage: Double) -> CGColor {
        switch usage {
        case ..<0.6:
            return NSColor.systemGreen.cgColor
        case ..<0.85:
            return NSColor.systemYellow.cgColor
        default:
            return NSColor.systemRed.cgColor
        }
    }

    private static func drawLabel(_ ctx: CGContext, text: String, in rect: CGRect, above y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 96, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        let lineWidth = CTLineGetImageBounds(line, ctx).width

        ctx.textPosition = CGPoint(x: (rect.width - lineWidth) / 2, y: rect.height - y - 110)
        CTLineDraw(line, ctx)
    }
}
