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
        drawBackground(in: ctx, rect: rect, state: state)
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

    // MARK: - Background (rounded blue squircle, macOS app-icon style)

    /// Macos-style rounded square with a vertical blue gradient. Provides
    /// contrast for the white pot and steam. Slightly darkens when the
    /// disconnected state is active.
    private static func drawBackground(in ctx: CGContext, rect: CGRect, state: IconState) {
        let cornerRadius = rect.width * 0.22
        let path = CGPath(roundedRect: rect,
                          cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                          transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()

        // Translucent so the Dock magnification highlight and surface tint show through.
        let colors: [CGColor]
        if state.isConnected {
            colors = [
                CGColor(red: 0.22, green: 0.46, blue: 0.78, alpha: 0.72),  // top
                CGColor(red: 0.10, green: 0.26, blue: 0.55, alpha: 0.72)   // bottom
            ]
        } else {
            colors = [
                CGColor(red: 0.28, green: 0.32, blue: 0.40, alpha: 0.65),
                CGColor(red: 0.14, green: 0.18, blue: 0.26, alpha: 0.65)
            ]
        }
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: colors as CFArray,
                                   locations: [0, 1])!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: rect.height),
            end:   CGPoint(x: 0, y: 0),
            options: [])
        ctx.restoreGState()
    }

    // MARK: - Disconnected pot (gray, no flame)

    private static func drawDisconnectedPot(in ctx: CGContext, rect: CGRect) {
        let bodyColor = NSColor(white: 0.55, alpha: 1).cgColor
        drawHandles(in: ctx, rect: rect, color: bodyColor)
        let body = CGPath(roundedRect:
            CGRect(x: rect.width * 0.16, y: rect.height * 0.36,
                   width: rect.width * 0.68, height: rect.height * 0.28),
            cornerWidth: 28, cornerHeight: 28, transform: nil)
        ctx.setFillColor(bodyColor)
        ctx.addPath(body); ctx.fillPath()

        // Lid
        ctx.setFillColor(NSColor(white: 0.42, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.width * 0.18, y: rect.height * 0.62,
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
        leftPath.move(to: CGPoint(x: rect.width * 0.18, y: rect.height * 0.46))
        leftPath.addCurve(
            to:        CGPoint(x: rect.width * 0.18, y: rect.height * 0.56),
            control1:  CGPoint(x: rect.width * 0.02, y: rect.height * 0.48),
            control2:  CGPoint(x: rect.width * 0.02, y: rect.height * 0.54))
        ctx.addPath(leftPath); ctx.strokePath()

        // Right handle: mirror
        let rightPath = CGMutablePath()
        rightPath.move(to: CGPoint(x: rect.width * 0.82, y: rect.height * 0.46))
        rightPath.addCurve(
            to:        CGPoint(x: rect.width * 0.82, y: rect.height * 0.56),
            control1:  CGPoint(x: rect.width * 0.98, y: rect.height * 0.48),
            control2:  CGPoint(x: rect.width * 0.98, y: rect.height * 0.54))
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
        let height = max(minHeight, rect.height * 0.32 * usage)
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
        let bodyDark  = scaleBrightness(bodyColor, by: 0.55)
        let bodyLight = scaleBrightness(bodyColor, by: 1.10, clamp: true)

        // Handles drawn behind the body so they appear to attach behind the rim
        drawHandles(in: ctx, rect: rect, color: bodyDark)

        let bodyRect = CGRect(x: rect.width * 0.16,
                              y: rect.height * 0.36,
                              width: rect.width * 0.68,
                              height: rect.height * 0.28)
        let body = CGPath(roundedRect: bodyRect,
                          cornerWidth: 28, cornerHeight: 28,
                          transform: nil)

        // 1) Drop shadow under the pot (sits on the cooktop)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -rect.width * 0.012),
                      blur: rect.width * 0.045,
                      color: CGColor(gray: 0, alpha: 0.55))
        ctx.setFillColor(bodyColor)
        ctx.addPath(body); ctx.fillPath()
        ctx.restoreGState()

        // 2) Vertical body gradient (darker at bottom, brighter at top) for 3D form
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [bodyLight, bodyColor, bodyDark] as CFArray,
            locations: [0.0, 0.5, 1.0])!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: bodyRect.maxY),
            end:   CGPoint(x: 0, y: bodyRect.minY),
            options: [])
        ctx.restoreGState()

        // 3) Specular vertical highlight on the upper-left of the body curvature
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        let highlightRect = CGRect(
            x: bodyRect.minX + bodyRect.width * 0.08,
            y: bodyRect.minY + bodyRect.height * 0.18,
            width: bodyRect.width * 0.10,
            height: bodyRect.height * 0.70)
        let hl = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
            ] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(
            hl,
            start: CGPoint(x: highlightRect.midX, y: highlightRect.midY),
            end:   CGPoint(x: highlightRect.midX + highlightRect.width, y: highlightRect.midY),
            options: [])
        ctx.restoreGState()

        // 4) Bottom inner shadow for added depth
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        let bottomShadow = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(gray: 0, alpha: 0.0),
                CGColor(gray: 0, alpha: 0.35)
            ] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(
            bottomShadow,
            start: CGPoint(x: 0, y: bodyRect.minY + bodyRect.height * 0.4),
            end:   CGPoint(x: 0, y: bodyRect.minY),
            options: [])
        ctx.restoreGState()
    }

    /// Multiplies RGB channels by `factor`. With `clamp: true` the result is
    /// clamped to [0, 1] (use when brightening past 1.0).
    private static func scaleBrightness(_ color: CGColor, by factor: CGFloat, clamp: Bool = false) -> CGColor {
        let c = color.components ?? [0.5, 0.5, 0.5, 1]
        let r = clamp ? min(1, c[0] * factor) : c[0] * factor
        let g = clamp ? min(1, c[1] * factor) : c[1] * factor
        let b = clamp ? min(1, c[2] * factor) : c[2] * factor
        let a = c.count > 3 ? c[3] : 1
        return CGColor(red: r, green: g, blue: b, alpha: a)
    }

    // MARK: - Steam + lid (with bounce when boiling)

    private static func drawSteamAndLid(in ctx: CGContext, rect: CGRect, state: IconState) {
        let lidY = rect.height * 0.62
        let lidOffset = state.boilingIntensity *
            sin(state.flameWigglePhase * 8) * rect.height * 0.012

        // Lid base with vertical gradient for 3D look
        let lidRect = CGRect(x: rect.width * 0.18, y: lidY + lidOffset,
                             width: rect.width * 0.64, height: rect.height * 0.06)
        let baseLid = lidColor(for: state.temperature)
        let lidLight = scaleBrightness(baseLid, by: 1.15, clamp: true)
        let lidDark  = scaleBrightness(baseLid, by: 0.65)
        ctx.saveGState()
        let lidPath = CGPath(ellipseIn: lidRect, transform: nil)
        ctx.addPath(lidPath); ctx.clip()
        let lidGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [lidLight, baseLid, lidDark] as CFArray,
            locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(
            lidGradient,
            start: CGPoint(x: 0, y: lidRect.maxY),
            end:   CGPoint(x: 0, y: lidRect.minY),
            options: [])
        ctx.restoreGState()

        // Knob with gradient (highlight + shadow) for depth
        let knobRect = CGRect(x: rect.width / 2 - rect.width * 0.035,
                              y: lidY + lidOffset + rect.height * 0.04,
                              width: rect.width * 0.07, height: rect.height * 0.035)
        ctx.saveGState()
        ctx.addPath(CGPath(ellipseIn: knobRect, transform: nil)); ctx.clip()
        let knobGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.40, green: 0.30, blue: 0.20, alpha: 1),  // top highlight
                CGColor(red: 0.20, green: 0.14, blue: 0.10, alpha: 1),  // mid
                CGColor(red: 0.10, green: 0.06, blue: 0.04, alpha: 1)   // bottom shadow
            ] as CFArray,
            locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(
            knobGradient,
            start: CGPoint(x: 0, y: knobRect.maxY),
            end:   CGPoint(x: 0, y: knobRect.minY),
            options: [])
        ctx.restoreGState()

        // Steam — count, height, and thickness scale with fan RPM (more steam
        // when fans spin harder). Mac Studio fans run ~1300 idle → ~3500 max,
        // so we normalize that range to a 0..1 intensity factor.
        let fanIntensity = fanIntensity(state: state)
        let count = steamStrandCount(state: state, fanIntensity: fanIntensity)
        if count == 0 { return }

        // Bold, opaque, wavy steam so it reads at Dock size.
        let lineWidth = rect.width * (0.045 + 0.030 * fanIntensity)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        let steamAlpha: CGFloat = 0.78 + 0.22 * fanIntensity
        let hotAlpha: CGFloat = min(1.0, steamAlpha)
        let coolColor = CGColor(red: 1, green: 1, blue: 1, alpha: steamAlpha)
        let hotColor  = CGColor(red: 1, green: 0.45, blue: 0.25, alpha: hotAlpha)
        let steamColor = lerpColor(from: coolColor, to: hotColor, t: state.boilingIntensity)
        ctx.setStrokeColor(steamColor)

        let baseX = rect.width * 0.50
        let stride = rect.width * 0.11
        let bottomY = rect.height * 0.68
        let topY    = rect.height * (0.94 + 0.04 * fanIntensity)
        let swayMag = stride * (0.45 + 0.50 * fanIntensity)

        // Five candidate strand positions; we draw the first `count`.
        // Sway sign alternates so adjacent strands wave in opposite directions.
        let strands: [(CGFloat, CGFloat)] = [
            (baseX,                  0.8),
            (baseX - stride,         1),
            (baseX + stride,        -1),
            (baseX - stride * 2.0,   1),
            (baseX + stride * 2.0,  -1)
        ]
        // Phase shift each strand so the wave crests don't all line up.
        for i in 0..<min(count, strands.count) {
            let (x, sway) = strands[i]
            let phaseShift = Double(i) * 0.5 + (state.flameWiggleEnabled ? state.flameWigglePhase * 0.3 : 0)
            drawWavyStrand(
                ctx: ctx,
                x: x,
                bottomY: bottomY, topY: topY,
                sway: sway,
                amplitude: swayMag,
                phase: phaseShift)
        }
    }

    /// Draws an upward squiggle ~ from `bottomY` to `topY`. Three quadratic
    /// segments that alternate left-right-left create the wavy look.
    private static func drawWavyStrand(ctx: CGContext,
                                       x: CGFloat,
                                       bottomY: CGFloat, topY: CGFloat,
                                       sway: CGFloat,
                                       amplitude: CGFloat,
                                       phase: Double) {
        let waves = 3
        let h = (topY - bottomY) / CGFloat(waves)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: bottomY))
        for w in 0..<waves {
            // Direction alternates each segment, starting from `sway`.
            let signValue: CGFloat = (w % 2 == 0) ? 1 : -1
            let dir: CGFloat = sway * signValue
            // Add a small phase-driven offset so multiple strands don't line up.
            let phaseOffset = CGFloat(sin(phase + Double(w) * .pi)) * amplitude * 0.15
            let yEnd  = bottomY + h * CGFloat(w + 1)
            let yCtrl = bottomY + h * (CGFloat(w) + 0.5)
            let xCtrl = x + dir * amplitude + phaseOffset
            path.addQuadCurve(to: CGPoint(x: x, y: yEnd),
                              control: CGPoint(x: xCtrl, y: yCtrl))
        }
        ctx.addPath(path)
        ctx.strokePath()
    }

    /// Mac Studio fans idle at ~1300 RPM and approach ~3500 RPM under sustained
    /// heavy load. Map that range to 0..1 for visual scaling.
    private static func fanIntensity(state: IconState) -> Double {
        guard let rpm = state.fanRPM else { return 0 }
        return max(0, min(1, (rpm - 1300) / 2200))
    }

    private static func steamStrandCount(state: IconState, fanIntensity: Double) -> Int {
        let usage = state.displayedUsage
        let base: Int
        switch usage {
        case ..<0.1:  base = 1   // always show at least one strand when connected
        case ..<0.5:  base = 2
        case ..<0.85: base = 3
        default:      base = 3
        }
        // Boiling adds one strand; high fan adds up to 2 more.
        let boilingExtra = state.boilingIntensity > 0.5 ? 1 : 0
        let fanExtra = fanIntensity >= 0.5 ? 2 : (fanIntensity >= 0.2 ? 1 : 0)
        return base + boilingExtra + fanExtra
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
