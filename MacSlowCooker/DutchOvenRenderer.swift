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
            drawPotBody(in: ctx, rect: rect, state: state)
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
        let bodyColor = NSColor(white: 0.55, alpha: 1).cgColor
        drawHandles(in: ctx, rect: rect, color: bodyColor)
        let body = CGPath(roundedRect:
            CGRect(x: rect.width * 0.16, y: rect.height * 0.42,
                   width: rect.width * 0.68, height: rect.height * 0.28),
            cornerWidth: 28, cornerHeight: 28, transform: nil)
        ctx.setFillColor(bodyColor)
        ctx.addPath(body); ctx.fillPath()

        // Lid
        ctx.setFillColor(NSColor(white: 0.42, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.width * 0.18, y: rect.height * 0.68,
                                   width: rect.width * 0.64, height: rect.height * 0.06))

        drawCenteredLabel("--", in: ctx, rect: rect, color: .gray, fontSize: 96)
    }

    /// Pot color: white when cool, blends through orange to red as temperature rises.
    /// Cool baseline = 50°C, full red at >= 95°C.
    private static func potColor(for temperature: Double?) -> CGColor {
        let t = temperature ?? 50
        let blend = max(0, min(1, (t - 50) / 45))   // 0 at 50°C, 1 at 95°C
        let b = CGFloat(blend)
        // White (0.97, 0.97, 0.95) → red-orange (0.92, 0.25, 0.15)
        let red:   CGFloat = 0.97 - 0.05 * b
        let green: CGFloat = 0.97 - 0.72 * b
        let blue:  CGFloat = 0.95 - 0.80 * b
        return CGColor(red: red, green: green, blue: blue, alpha: 1)
    }

    /// Lid is slightly darker than the pot for depth.
    private static func lidColor(for temperature: Double?) -> CGColor {
        let pot = potColor(for: temperature).components ?? [0.85, 0.85, 0.83, 1]
        return CGColor(red: pot[0] * 0.85, green: pot[1] * 0.82, blue: pot[2] * 0.80, alpha: 1)
    }

    /// Loop handles on either side of the pot. Drawn before the body so they appear
    /// to attach behind the pot rim.
    private static func drawHandles(in ctx: CGContext, rect: CGRect, color: CGColor) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(rect.width * 0.045)
        ctx.setLineCap(.round)

        // Left handle: D-shaped loop
        let leftPath = CGMutablePath()
        leftPath.move(to: CGPoint(x: rect.width * 0.18, y: rect.height * 0.52))
        leftPath.addCurve(
            to:        CGPoint(x: rect.width * 0.18, y: rect.height * 0.62),
            control1:  CGPoint(x: rect.width * 0.02, y: rect.height * 0.54),
            control2:  CGPoint(x: rect.width * 0.02, y: rect.height * 0.60))
        ctx.addPath(leftPath); ctx.strokePath()

        // Right handle: mirror
        let rightPath = CGMutablePath()
        rightPath.move(to: CGPoint(x: rect.width * 0.82, y: rect.height * 0.52))
        rightPath.addCurve(
            to:        CGPoint(x: rect.width * 0.82, y: rect.height * 0.62),
            control1:  CGPoint(x: rect.width * 0.98, y: rect.height * 0.54),
            control2:  CGPoint(x: rect.width * 0.98, y: rect.height * 0.60))
        ctx.addPath(rightPath); ctx.strokePath()
    }

    // MARK: - Flame

    private static func drawFlame(in ctx: CGContext, rect: CGRect, state: IconState) {
        let usage = max(0, min(1, state.displayedUsage))
        guard usage > 0.01 else { return }

        let cx = rect.width / 2
        let baseY = rect.height * 0.04
        // Min height so the flame stays visible at idle; scales up to ~38% at full load
        // so the flame and pot have comparable visual weight.
        let minHeight = rect.height * 0.08
        let height = max(minHeight, rect.height * 0.38 * usage)
        let halfWidth = rect.width * 0.24 * sqrt(max(0.25, usage))

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

    private static func drawPotBody(in ctx: CGContext, rect: CGRect, state: IconState) {
        let bodyColor = potColor(for: state.temperature)
        // Draw handles first so they sit behind the body
        drawHandles(in: ctx, rect: rect, color: bodyColor)

        let body = CGPath(
            roundedRect: CGRect(x: rect.width * 0.16,
                                y: rect.height * 0.42,
                                width: rect.width * 0.68,
                                height: rect.height * 0.28),
            cornerWidth: 28, cornerHeight: 28, transform: nil)
        ctx.setFillColor(bodyColor)
        ctx.addPath(body); ctx.fillPath()
    }

    // MARK: - Steam + lid (with bounce when boiling)

    private static func drawSteamAndLid(in ctx: CGContext, rect: CGRect, state: IconState) {
        let lidY = rect.height * 0.68
        let lidOffset = state.boilingIntensity *
            sin(state.flameWigglePhase * 8) * rect.height * 0.012

        // Lid base — slightly darker than the body for depth
        ctx.setFillColor(lidColor(for: state.temperature))
        ctx.fillEllipse(in: CGRect(x: rect.width * 0.18, y: lidY + lidOffset,
                                   width: rect.width * 0.64, height: rect.height * 0.06))
        // Knob (always dark for contrast)
        ctx.setFillColor(NSColor(red: 0.20, green: 0.14, blue: 0.10, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.width / 2 - rect.width * 0.035,
                                   y: lidY + lidOffset + rect.height * 0.04,
                                   width: rect.width * 0.07, height: rect.height * 0.035))

        // Steam
        let count = steamStrandCount(state: state)
        if count == 0 { return }

        ctx.setLineWidth(rect.width * 0.014)
        ctx.setLineCap(.round)
        let steamColor = lerpColor(from: CGColor(red: 1, green: 1, blue: 1, alpha: 0.6),
                                   to:   CGColor(red: 1, green: 0.5, blue: 0.3, alpha: 0.9),
                                   t: state.boilingIntensity)
        ctx.setStrokeColor(steamColor)

        let baseX = rect.width * 0.50
        let stride = rect.width * 0.10
        let topY  = rect.height * 0.96
        let bottomY = rect.height * 0.76

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
                                   y: rect.height * 0.50)
        CTLineDraw(line, ctx)
    }
}
