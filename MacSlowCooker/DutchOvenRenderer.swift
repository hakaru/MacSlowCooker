import AppKit
import CoreGraphics
import os.log

private let renderLog = OSLog(subsystem: "com.macslowcooker", category: "render")

enum DutchOvenRenderer: PotRenderer {

    // MARK: - Public

    static func render(state: IconState) -> NSImage {
        let size = iconSize
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            os_log("CGContext creation failed", log: renderLog, type: .error)
            return NSImage(size: size)
        }

        let rect = CGRect(origin: .zero, size: size)
        if state.isConnected {
            drawFlame(in: ctx, rect: rect, state: state)
            drawPotBody(in: ctx, rect: rect)
            drawSteamAndLid(in: ctx, rect: rect, state: state)
        } else {
            drawDisconnectedPot(in: ctx, rect: rect)
        }

        guard let cgImage = ctx.makeImage() else {
            os_log("CGContext makeImage failed", log: renderLog, type: .error)
            return NSImage(size: size)
        }
        return NSImage(cgImage: cgImage, size: size)
    }

    // MARK: - Disconnected pot (gray, no flame)

    private static func drawDisconnectedPot(in ctx: CGContext, rect: CGRect) {
        let body = CGPath(roundedRect:
            CGRect(x: rect.width * 0.14, y: rect.height * 0.20,
                   width: rect.width * 0.72, height: rect.height * 0.32),
            cornerWidth: 24, cornerHeight: 24, transform: nil)
        ctx.setFillColor(NSColor(white: 0.22, alpha: 1).cgColor)
        ctx.addPath(body); ctx.fillPath()

        // Lid
        ctx.setFillColor(NSColor(white: 0.30, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.width * 0.16, y: rect.height * 0.50,
                                   width: rect.width * 0.68, height: rect.height * 0.06))

        drawCenteredLabel("--", in: ctx, rect: rect, color: .gray, fontSize: 96)
    }

    // MARK: - Flame

    private static func drawFlame(in ctx: CGContext, rect: CGRect, state: IconState) {
        let usage = max(0, min(1, state.displayedUsage))
        guard usage > 0.01 else { return }

        let cx = rect.width / 2
        let baseY = rect.height * 0.18
        let height = rect.height * 0.18 * usage
        let halfWidth = rect.width * 0.18 * sqrt(usage)

        // Optional wiggle distortion of bezier control points
        let phase = state.flameWiggleEnabled ? state.flameWigglePhase : 0
        let wiggleX = sin(phase) * rect.width * 0.01
        let wiggleY = cos(phase * 1.3) * height * 0.06

        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx - halfWidth, y: baseY))
        path.addQuadCurve(
            to: CGPoint(x: cx + wiggleX, y: baseY + height + wiggleY),
            control: CGPoint(x: cx - halfWidth * 0.5 + wiggleX, y: baseY + height * 0.7))
        path.addQuadCurve(
            to: CGPoint(x: cx + halfWidth, y: baseY),
            control: CGPoint(x: cx + halfWidth * 0.6 - wiggleX, y: baseY + height * 0.5))
        path.closeSubpath()

        // Color shifts redder at high usage
        let red:    CGFloat = usage < 0.6 ? 1.0 : 1.0
        let green:  CGFloat = usage < 0.6 ? 0.7 : (usage < 0.85 ? 0.55 : 0.3)
        let blue:   CGFloat = 0.15

        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 0.95))
        ctx.addPath(path); ctx.fillPath()

        // Inner brighter flame
        let innerPath = CGMutablePath()
        innerPath.move(to: CGPoint(x: cx - halfWidth * 0.5, y: baseY))
        innerPath.addQuadCurve(
            to: CGPoint(x: cx + wiggleX * 0.5, y: baseY + height * 0.85 + wiggleY * 0.5),
            control: CGPoint(x: cx - halfWidth * 0.25, y: baseY + height * 0.5))
        innerPath.addQuadCurve(
            to: CGPoint(x: cx + halfWidth * 0.5, y: baseY),
            control: CGPoint(x: cx + halfWidth * 0.3, y: baseY + height * 0.4))
        innerPath.closeSubpath()
        ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.3, alpha: 0.85))
        ctx.addPath(innerPath); ctx.fillPath()
    }

    // MARK: - Pot body + handles

    private static func drawPotBody(in ctx: CGContext, rect: CGRect) {
        let body = CGPath(
            roundedRect: CGRect(x: rect.width * 0.14,
                                y: rect.height * 0.20,
                                width: rect.width * 0.72,
                                height: rect.height * 0.32),
            cornerWidth: 24, cornerHeight: 24, transform: nil)
        ctx.setFillColor(NSColor(white: 0.10, alpha: 1).cgColor)
        ctx.addPath(body); ctx.fillPath()

        // Handles
        ctx.setStrokeColor(NSColor(white: 0.10, alpha: 1).cgColor)
        ctx.setLineWidth(rect.width * 0.018)
        ctx.setLineCap(.round)

        ctx.move(to: CGPoint(x: rect.width * 0.10, y: rect.height * 0.46))
        ctx.addLine(to: CGPoint(x: rect.width * 0.06, y: rect.height * 0.48))
        ctx.addLine(to: CGPoint(x: rect.width * 0.10, y: rect.height * 0.50))
        ctx.strokePath()

        ctx.move(to: CGPoint(x: rect.width * 0.90, y: rect.height * 0.46))
        ctx.addLine(to: CGPoint(x: rect.width * 0.94, y: rect.height * 0.48))
        ctx.addLine(to: CGPoint(x: rect.width * 0.90, y: rect.height * 0.50))
        ctx.strokePath()
    }

    // MARK: - Steam + lid (with bounce when boiling)

    private static func drawSteamAndLid(in ctx: CGContext, rect: CGRect, state: IconState) {
        let lidY = rect.height * 0.50
        let lidOffset = state.boilingIntensity *
            sin(state.flameWigglePhase * 8) * rect.height * 0.012

        // Lid base
        ctx.setFillColor(NSColor(white: 0.05, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.width * 0.16, y: lidY + lidOffset,
                                   width: rect.width * 0.68, height: rect.height * 0.05))
        // Lid top accent
        ctx.setFillColor(NSColor(white: 0.18, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.width * 0.20, y: lidY + lidOffset + rect.height * 0.008,
                                   width: rect.width * 0.60, height: rect.height * 0.03))
        // Knob
        ctx.setFillColor(NSColor(red: 0.32, green: 0.24, blue: 0.16, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.width / 2 - rect.width * 0.025,
                                   y: lidY + lidOffset + rect.height * 0.04,
                                   width: rect.width * 0.05, height: rect.height * 0.025))

        // Steam
        let count = steamStrandCount(state: state)
        if count == 0 { return }

        ctx.setLineWidth(rect.width * 0.012)
        ctx.setLineCap(.round)
        let steamColor = lerpColor(from: CGColor(red: 1, green: 1, blue: 1, alpha: 0.5),
                                   to:   CGColor(red: 1, green: 0.6, blue: 0.4, alpha: 0.8),
                                   t: state.boilingIntensity)
        ctx.setStrokeColor(steamColor)

        let baseX = rect.width * 0.50
        let stride = rect.width * 0.10
        let topY  = rect.height * 0.78
        let bottomY = rect.height * 0.55

        let strands: [(CGFloat, CGFloat)] = [
            (baseX,            0),
            (baseX - stride,   1),
            (baseX + stride,  -1),
            (baseX + stride*2, 0)
        ]
        for i in 0..<count {
            let (x, sway) = strands[i]
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: bottomY))
            path.addQuadCurve(
                to: CGPoint(x: x + sway * stride * 0.3, y: topY),
                control: CGPoint(x: x - sway * stride * 0.4, y: (bottomY + topY) / 2))
            ctx.addPath(path); ctx.strokePath()
        }
    }

    private static func steamStrandCount(state: IconState) -> Int {
        let usage = state.displayedUsage
        let base: Int
        switch usage {
        case ..<0.2:  base = 0
        case ..<0.6:  base = 1
        case ..<0.9:  base = 2
        default:      base = 2
        }
        // Boiling adds an extra strand once intensity is high enough
        return base + (state.boilingIntensity > 0.5 ? 1 : 0)
    }

    private static func lerpColor(from a: CGColor, to b: CGColor, t: Double) -> CGColor {
        let t = max(0, min(1, t))
        let ac = a.components ?? [1,1,1,1]
        let bc = b.components ?? [1,1,1,1]
        return CGColor(red:   ac[0] * (1-t) + bc[0] * t,
                       green: ac[1] * (1-t) + bc[1] * t,
                       blue:  ac[2] * (1-t) + bc[2] * t,
                       alpha: ac[3] * (1-t) + bc[3] * t)
    }

    // MARK: - Label

    private static func drawCenteredLabel(_ text: String, in ctx: CGContext, rect: CGRect,
                                          color: NSColor, fontSize: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetImageBounds(line, ctx)
        ctx.textPosition = CGPoint(x: (rect.width - bounds.width) / 2,
                                   y: rect.height * 0.30)
        CTLineDraw(line, ctx)
    }
}
