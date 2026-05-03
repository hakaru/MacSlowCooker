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
            drawFlameHalo(in: ctx, rect: rect, state: state)
            drawFlame(in: ctx, rect: rect, state: state)
            drawHandles(in: ctx, rect: rect, color: handleColor(state: state))
            drawPotBackRim(in: ctx, rect: rect, state: state)
            drawPotBody(in: ctx, rect: rect, state: state)
            drawLid(in: ctx, rect: rect, state: state)
            drawSteam(in: ctx, rect: rect, state: state)
        } else {
            drawDisconnectedPot(in: ctx, rect: rect)
        }

        guard let cgImage = ctx.makeImage() else {
            os_log("CGContext makeImage failed", log: renderLog, type: .error)
            return NSImage(size: size)
        }
        return NSImage(cgImage: cgImage, size: size)
    }

    // MARK: - Geometry constants
    //
    // The pot is rendered as a drum (cylinder) viewed from a slight upper
    // angle so the top rim and bottom edge both read as ellipses. Every
    // coordinate below is a fraction of the icon's full rect, so the layout
    // scales with `iconSize` without further tuning.

    private struct PotGeometry {
        let centerX: CGFloat
        let halfWidth: CGFloat        // body half-width (= rim widest half-width)
        let topY: CGFloat             // rim midline (where left/right of rim ellipse sit)
        let bottomY: CGFloat          // bottom ellipse midline
        let rimHalfHeight: CGFloat    // half-thickness of the visible rim ellipse
        let bottomHalfHeight: CGFloat // half-thickness of the visible bottom ellipse
        let lidApexY: CGFloat         // tallest point of the dome lid

        static func standard(in rect: CGRect) -> PotGeometry {
            PotGeometry(
                centerX:          rect.width  * 0.50,
                halfWidth:        rect.width  * 0.31,
                topY:             rect.height * 0.58,
                bottomY:          rect.height * 0.32,
                rimHalfHeight:    rect.height * 0.030,
                bottomHalfHeight: rect.height * 0.022,
                lidApexY:         rect.height * 0.70
            )
        }
    }

    // MARK: - Background (rounded blue squircle, macOS app-icon style)

    private static func drawBackground(in ctx: CGContext, rect: CGRect, state: IconState) {
        let cornerRadius = rect.width * 0.22
        let path = CGPath(roundedRect: rect,
                          cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                          transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()

        // Brighter, airier blue with a more visible top→bottom gradient.
        // Top stays light enough to feel like sky/steam-room atmosphere; bottom
        // sits dark enough to anchor the pot and provide flame contrast.
        let colors: [CGColor]
        let locations: [CGFloat]
        if state.isConnected {
            colors = [
                CGColor(red: 0.62, green: 0.80, blue: 0.96, alpha: 0.70),  // top sky
                CGColor(red: 0.36, green: 0.58, blue: 0.88, alpha: 0.70),  // mid
                CGColor(red: 0.14, green: 0.32, blue: 0.62, alpha: 0.70)   // bottom anchor
            ]
            locations = [0.0, 0.45, 1.0]
        } else {
            colors = [
                CGColor(red: 0.40, green: 0.46, blue: 0.55, alpha: 0.65),
                CGColor(red: 0.20, green: 0.24, blue: 0.32, alpha: 0.65)
            ]
            locations = [0.0, 1.0]
        }
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: colors as CFArray,
                                   locations: locations)!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: rect.height),
            end:   CGPoint(x: 0, y: 0),
            options: [])
        ctx.restoreGState()
    }

    // MARK: - Disconnected pot (gray, no flame)

    private static func drawDisconnectedPot(in ctx: CGContext, rect: CGRect) {
        let g = PotGeometry.standard(in: rect)
        let bodyColor = NSColor(white: 0.55, alpha: 1).cgColor
        drawHandles(in: ctx, rect: rect, color: NSColor(white: 0.42, alpha: 1).cgColor)
        // Solid drum silhouette
        ctx.setFillColor(bodyColor)
        ctx.addPath(potBodyPath(g: g))
        ctx.fillPath()
        // Lid dome
        ctx.setFillColor(NSColor(white: 0.42, alpha: 1).cgColor)
        ctx.addPath(lidDomePath(g: g, lidOffset: 0))
        ctx.fillPath()
        drawCenteredLabel("--", in: ctx, rect: rect, color: .gray, fontSize: 96)
    }

    // MARK: - Color helpers

    /// Pot color: white when cool, blends through orange to red as temperature rises.
    /// Cool baseline = 50°C, full red at >= 95°C.
    private static func potColor(for temperature: Double?) -> CGColor {
        let t = temperature ?? 50
        let blend = max(0, min(1, (t - 50) / 45))
        let b = CGFloat(blend)
        let red:   CGFloat = 0.97 - 0.05 * b
        let green: CGFloat = 0.97 - 0.72 * b
        let blue:  CGFloat = 0.95 - 0.80 * b
        return CGColor(red: red, green: green, blue: blue, alpha: 1)
    }

    private static func lidColor(for temperature: Double?) -> CGColor {
        let pot = potColor(for: temperature).components ?? [0.85, 0.85, 0.83, 1]
        return CGColor(red: pot[0] * 0.85, green: pot[1] * 0.82, blue: pot[2] * 0.80, alpha: 1)
    }

    private static func rimShadowColor(for temperature: Double?) -> CGColor {
        let pot = potColor(for: temperature).components ?? [0.85, 0.85, 0.83, 1]
        return CGColor(red: pot[0] * 0.55, green: pot[1] * 0.50, blue: pot[2] * 0.48, alpha: 1)
    }

    private static func handleColor(state: IconState) -> CGColor {
        scaleBrightness(potColor(for: state.temperature), by: 0.45)
    }

    /// Multiplies RGB channels by `factor`. With `clamp: true` clamps to [0,1].
    private static func scaleBrightness(_ color: CGColor, by factor: CGFloat, clamp: Bool = false) -> CGColor {
        let c = color.components ?? [0.5, 0.5, 0.5, 1]
        let r = clamp ? min(1, c[0] * factor) : c[0] * factor
        let g = clamp ? min(1, c[1] * factor) : c[1] * factor
        let b = clamp ? min(1, c[2] * factor) : c[2] * factor
        let a = c.count > 3 ? c[3] : 1
        return CGColor(red: r, green: g, blue: b, alpha: a)
    }

    // MARK: - Pot path builders

    /// Drum-shape body silhouette: vertical sides closed at the top by the
    /// front (lower) half of the rim ellipse and at the bottom by the front
    /// (lower) half of the base ellipse. Both halves bulge downward in screen
    /// coords so the pot reads as a cylinder viewed from slightly above.
    private static func potBodyPath(g: PotGeometry) -> CGPath {
        let body = CGMutablePath()
        let leftX = g.centerX - g.halfWidth
        let rightX = g.centerX + g.halfWidth
        // 4/3 is the standard bezier approximation factor for a half-circle
        // by a single cubic; works well enough for these shallow ellipses.
        let k: CGFloat = 4.0 / 3.0

        body.move(to: CGPoint(x: leftX, y: g.topY))
        body.addLine(to: CGPoint(x: leftX, y: g.bottomY))
        // Front half of bottom ellipse: bulges downward
        body.addCurve(
            to:        CGPoint(x: rightX, y: g.bottomY),
            control1:  CGPoint(x: leftX,  y: g.bottomY - g.bottomHalfHeight * k),
            control2:  CGPoint(x: rightX, y: g.bottomY - g.bottomHalfHeight * k))
        body.addLine(to: CGPoint(x: rightX, y: g.topY))
        // Front half of rim ellipse: bulges downward into the body
        body.addCurve(
            to:        CGPoint(x: leftX,  y: g.topY),
            control1:  CGPoint(x: rightX, y: g.topY - g.rimHalfHeight * k),
            control2:  CGPoint(x: leftX,  y: g.topY - g.rimHalfHeight * k))
        body.closeSubpath()
        return body
    }

    /// Back half of the rim ellipse — the curved sliver visible above the body
    /// silhouette and behind the lid. Drawn separately so we can give it its
    /// own (darker) shading without re-clipping the body fill.
    private static func potBackRimPath(g: PotGeometry) -> CGPath {
        let path = CGMutablePath()
        let leftX = g.centerX - g.halfWidth
        let rightX = g.centerX + g.halfWidth
        let k: CGFloat = 4.0 / 3.0

        path.move(to: CGPoint(x: leftX, y: g.topY))
        // Back half: bulges upward (we're looking down on it)
        path.addCurve(
            to:        CGPoint(x: rightX, y: g.topY),
            control1:  CGPoint(x: leftX,  y: g.topY + g.rimHalfHeight * k),
            control2:  CGPoint(x: rightX, y: g.topY + g.rimHalfHeight * k))
        // Front half completes the closed ellipse
        path.addCurve(
            to:        CGPoint(x: leftX,  y: g.topY),
            control1:  CGPoint(x: rightX, y: g.topY - g.rimHalfHeight * k),
            control2:  CGPoint(x: leftX,  y: g.topY - g.rimHalfHeight * k))
        path.closeSubpath()
        return path
    }

    /// Lid: dome rising from the rim (back half ellipse) up to a single apex.
    /// `lidOffset` shifts the whole dome vertically (used for boiling bounce).
    private static func lidDomePath(g: PotGeometry, lidOffset: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let leftX = g.centerX - g.halfWidth * 0.96
        let rightX = g.centerX + g.halfWidth * 0.96
        let baseY = g.topY + lidOffset
        let apexY = g.lidApexY + lidOffset

        // Start on the back-left of the rim where the lid meets the pot
        path.move(to: CGPoint(x: leftX, y: baseY))
        // Sweep up over the dome with a cubic; control points biased slightly
        // toward the apex for an oval (not pointy) silhouette.
        path.addCurve(
            to:        CGPoint(x: rightX, y: baseY),
            control1:  CGPoint(x: leftX,  y: apexY),
            control2:  CGPoint(x: rightX, y: apexY))
        // Close along the rim's BACK half so the dome plus this curve form a
        // sealed dome+rim cap. Control points mirror those of potBackRimPath
        // so the seam is invisible.
        let k: CGFloat = 4.0 / 3.0
        path.addCurve(
            to:        CGPoint(x: leftX,  y: baseY),
            control1:  CGPoint(x: rightX, y: baseY + g.rimHalfHeight * k),
            control2:  CGPoint(x: leftX,  y: baseY + g.rimHalfHeight * k))
        path.closeSubpath()
        return path
    }

    // MARK: - Pot back rim (drawn before body, behind lid)

    private static func drawPotBackRim(in ctx: CGContext, rect: CGRect, state: IconState) {
        let g = PotGeometry.standard(in: rect)
        let rimColor = rimShadowColor(for: state.temperature)
        ctx.setFillColor(rimColor)
        ctx.addPath(potBackRimPath(g: g))
        ctx.fillPath()
    }

    // MARK: - Pot body (drum silhouette with shading)

    private static func drawPotBody(in ctx: CGContext, rect: CGRect, state: IconState) {
        let g = PotGeometry.standard(in: rect)
        let bodyColor = potColor(for: state.temperature)
        let bodyDark  = scaleBrightness(bodyColor, by: 0.55)
        let bodyLight = scaleBrightness(bodyColor, by: 1.10, clamp: true)

        let body = potBodyPath(g: g)

        // 1) Drop shadow under the pot
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -rect.width * 0.012),
                      blur: rect.width * 0.045,
                      color: CGColor(gray: 0, alpha: 0.55))
        ctx.setFillColor(bodyColor)
        ctx.addPath(body); ctx.fillPath()
        ctx.restoreGState()

        // 2) Vertical gradient — bright top, dark bottom
        ctx.saveGState()
        ctx.addPath(body); ctx.clip()
        let bodyBounds = body.boundingBox
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [bodyLight, bodyColor, bodyDark] as CFArray,
            locations: [0.0, 0.55, 1.0])!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: bodyBounds.maxY),
            end:   CGPoint(x: 0, y: bodyBounds.minY),
            options: [])
        ctx.restoreGState()

        // 3) Cylindrical horizontal shading — dark edges, bright center, dark edges.
        //    Mimics the curved sides of a real cylinder under a single light source.
        ctx.saveGState()
        ctx.addPath(body); ctx.clip()
        let cylShade = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(gray: 0, alpha: 0.45),   // far left edge
                CGColor(gray: 0, alpha: 0.0),    // ~22%
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),  // ~38% (highlight band)
                CGColor(gray: 0, alpha: 0.0),    // ~75%
                CGColor(gray: 0, alpha: 0.40)    // far right edge
            ] as CFArray,
            locations: [0, 0.22, 0.38, 0.75, 1])!
        ctx.drawLinearGradient(
            cylShade,
            start: CGPoint(x: bodyBounds.minX, y: 0),
            end:   CGPoint(x: bodyBounds.maxX, y: 0),
            options: [])
        ctx.restoreGState()

        // 4) Front rim shadow — the front lip of the rim casts a soft shadow
        //    on the body just below it.
        ctx.saveGState()
        ctx.addPath(body); ctx.clip()
        let rimShade = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(gray: 0, alpha: 0.35),
                CGColor(gray: 0, alpha: 0.0)
            ] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(
            rimShade,
            start: CGPoint(x: 0, y: g.topY),
            end:   CGPoint(x: 0, y: g.topY - rect.height * 0.06),
            options: [])
        ctx.restoreGState()
    }

    // MARK: - Lid (dome with knob)

    private static func drawLid(in ctx: CGContext, rect: CGRect, state: IconState) {
        let g = PotGeometry.standard(in: rect)
        let lidOffset = state.boilingIntensity *
            sin(state.flameWigglePhase * 8) * rect.height * 0.012

        let baseLid = lidColor(for: state.temperature)
        let lidLight = scaleBrightness(baseLid, by: 1.20, clamp: true)
        let lidDark  = scaleBrightness(baseLid, by: 0.55)

        let dome = lidDomePath(g: g, lidOffset: lidOffset)
        let domeBounds = dome.boundingBox

        // Dome fill — radial-feeling vertical gradient (bright top, dark sides)
        ctx.saveGState()
        ctx.addPath(dome); ctx.clip()
        let lidGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [lidLight, baseLid, lidDark] as CFArray,
            locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(
            lidGradient,
            start: CGPoint(x: 0, y: domeBounds.maxY),
            end:   CGPoint(x: 0, y: domeBounds.minY),
            options: [])
        ctx.restoreGState()

        // Specular highlight — small bright crescent on the upper-left of dome
        ctx.saveGState()
        ctx.addPath(dome); ctx.clip()
        let highlight = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.55),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
            ] as CFArray,
            locations: [0, 1])!
        let hlCenter = CGPoint(
            x: g.centerX - g.halfWidth * 0.45,
            y: g.lidApexY + lidOffset - rect.height * 0.015)
        ctx.drawRadialGradient(
            highlight,
            startCenter: hlCenter, startRadius: 0,
            endCenter:   hlCenter, endRadius:   rect.width * 0.10,
            options: [])
        ctx.restoreGState()

        // Knob: small dome on top of the lid apex
        let knobR = rect.width * 0.045
        let knobCenter = CGPoint(x: g.centerX, y: g.lidApexY + lidOffset + knobR * 0.4)
        let knobRect = CGRect(
            x: knobCenter.x - knobR, y: knobCenter.y - knobR * 0.7,
            width: knobR * 2, height: knobR * 1.4)
        let knobPath = CGPath(ellipseIn: knobRect, transform: nil)
        ctx.saveGState()
        ctx.addPath(knobPath); ctx.clip()
        let knobGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.40, green: 0.30, blue: 0.20, alpha: 1),
                CGColor(red: 0.20, green: 0.14, blue: 0.10, alpha: 1),
                CGColor(red: 0.10, green: 0.06, blue: 0.04, alpha: 1)
            ] as CFArray,
            locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(
            knobGradient,
            start: CGPoint(x: 0, y: knobRect.maxY),
            end:   CGPoint(x: 0, y: knobRect.minY),
            options: [])
        ctx.restoreGState()
    }

    // MARK: - Handles

    /// Loop handles attached at the rim sides, behind the body so they appear
    /// to ride on the back of the pot. Repositioned for the drum geometry.
    private static func drawHandles(in ctx: CGContext, rect: CGRect, color: CGColor) {
        let g = PotGeometry.standard(in: rect)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(rect.width * 0.080)        // chunky stroke
        ctx.setLineCap(.round)

        let leftAttachX = g.centerX - g.halfWidth + rect.width * 0.005
        let rightAttachX = g.centerX + g.halfWidth - rect.width * 0.005
        // Taller, wider loop — handles read clearly even at small Dock sizes.
        let attachTop = g.topY + rect.height * 0.010
        let attachBot = g.topY - rect.height * 0.200
        let bulge = rect.width * 0.150               // wider outward arc

        let leftPath = CGMutablePath()
        leftPath.move(to: CGPoint(x: leftAttachX, y: attachTop))
        leftPath.addCurve(
            to:        CGPoint(x: leftAttachX, y: attachBot),
            control1:  CGPoint(x: leftAttachX - bulge, y: attachTop - rect.height * 0.005),
            control2:  CGPoint(x: leftAttachX - bulge, y: attachBot + rect.height * 0.005))
        ctx.addPath(leftPath); ctx.strokePath()

        let rightPath = CGMutablePath()
        rightPath.move(to: CGPoint(x: rightAttachX, y: attachTop))
        rightPath.addCurve(
            to:        CGPoint(x: rightAttachX, y: attachBot),
            control1:  CGPoint(x: rightAttachX + bulge, y: attachTop - rect.height * 0.005),
            control2:  CGPoint(x: rightAttachX + bulge, y: attachBot + rect.height * 0.005))
        ctx.addPath(rightPath); ctx.strokePath()
    }

    // MARK: - Flame (asymmetric layered, 🔥-like)

    /// Soft glow halo behind the flame so high usage radiates onto the pot.
    private static func drawFlameHalo(in ctx: CGContext, rect: CGRect, state: IconState) {
        let usage = max(0, min(1, state.displayedUsage))
        guard usage > 0.05 else { return }
        let g = PotGeometry.standard(in: rect)
        let center = CGPoint(x: g.centerX, y: rect.height * 0.22)
        let radius = rect.width * (0.18 + 0.14 * usage)
        ctx.saveGState()
        let halo = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 1.0, green: 0.55, blue: 0.10, alpha: 0.45 * usage),
                CGColor(red: 1.0, green: 0.30, blue: 0.05, alpha: 0.0)
            ] as CFArray,
            locations: [0, 1])!
        ctx.drawRadialGradient(
            halo,
            startCenter: center, startRadius: 0,
            endCenter:   center, endRadius:   radius,
            options: [])
        ctx.restoreGState()
    }

    /// Asymmetric three-layer flame styled after the 🔥 emoji silhouette:
    /// outer red-orange body, middle orange lobe, bright yellow-white core.
    /// The outer body has a wider belly and a curling top tip; layers stack
    /// concentrically so the brightest color is always at the heart.
    private static func drawFlame(in ctx: CGContext, rect: CGRect, state: IconState) {
        let usage = max(0, min(1, state.displayedUsage))
        guard usage > 0.01 else { return }

        let cx = rect.width * 0.50
        let baseY = rect.height * 0.06
        let minHeight = rect.height * 0.10
        let height = max(minHeight, rect.height * 0.34 * usage)
        let width = rect.width * 0.30 * sqrt(max(0.30, usage))

        // Wiggle distorts both the tip position and curl direction
        let phase = state.flameWiggleEnabled ? state.flameWigglePhase : 0
        let tipDriftX = sin(phase) * width * 0.10
        let tipDriftY = cos(phase * 1.3) * height * 0.04

        // Outer flame: red-orange, wide belly, curling tip
        let outer = flamePath(
            cx: cx, baseY: baseY,
            width: width, height: height,
            tipDriftX: tipDriftX, tipDriftY: tipDriftY)
        let outerColor: CGColor = {
            // Hotter at high usage (more red)
            let r: CGFloat = 1.0
            let gr: CGFloat = usage < 0.6 ? 0.45 : (usage < 0.85 ? 0.32 : 0.18)
            let b: CGFloat = 0.10
            return CGColor(red: r, green: gr, blue: b, alpha: 0.96)
        }()
        ctx.setFillColor(outerColor)
        ctx.addPath(outer); ctx.fillPath()

        // Middle flame: orange, ~70% size, sits inside the outer
        let middle = flamePath(
            cx: cx, baseY: baseY + height * 0.05,
            width: width * 0.62, height: height * 0.78,
            tipDriftX: tipDriftX * 0.8, tipDriftY: tipDriftY * 0.8)
        ctx.setFillColor(CGColor(red: 1.0, green: 0.70, blue: 0.20, alpha: 0.92))
        ctx.addPath(middle); ctx.fillPath()

        // Inner core: bright yellow-white, ~35% size, slightly off-center toward tip
        let coreOffsetX = tipDriftX * 0.5
        let core = flamePath(
            cx: cx + coreOffsetX, baseY: baseY + height * 0.18,
            width: width * 0.32, height: height * 0.50,
            tipDriftX: tipDriftX * 0.5, tipDriftY: tipDriftY * 0.5)
        ctx.setFillColor(CGColor(red: 1.0, green: 0.95, blue: 0.55, alpha: 0.95))
        ctx.addPath(core); ctx.fillPath()
    }

    /// Builds an asymmetric teardrop with a curling tip. The tip drift offsets
    /// shift only the apex so wiggle reads as the flame swaying at the top
    /// rather than the entire body translating — closer to how a real flame
    /// behaves under air currents.
    private static func flamePath(
        cx: CGFloat,
        baseY: CGFloat,
        width: CGFloat,
        height: CGFloat,
        tipDriftX: CGFloat,
        tipDriftY: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let halfW = width / 2
        let topY = baseY + height + tipDriftY
        let tipX = cx + tipDriftX

        // Bottom-left
        path.move(to: CGPoint(x: cx - halfW, y: baseY))
        // Up the left side, with a slight outward bulge in the lower third
        path.addCurve(
            to:        CGPoint(x: cx - halfW * 0.25, y: baseY + height * 0.85),
            control1:  CGPoint(x: cx - halfW * 1.15, y: baseY + height * 0.30),
            control2:  CGPoint(x: cx - halfW * 0.95, y: baseY + height * 0.65))
        // Up to the apex
        path.addQuadCurve(
            to:      CGPoint(x: tipX, y: topY),
            control: CGPoint(x: cx - halfW * 0.10, y: baseY + height * 0.95))
        // Curl back down the right side, narrower and steeper than left
        path.addQuadCurve(
            to:      CGPoint(x: cx + halfW * 0.55, y: baseY + height * 0.70),
            control: CGPoint(x: cx + halfW * 0.85, y: baseY + height * 0.95))
        path.addCurve(
            to:        CGPoint(x: cx + halfW, y: baseY),
            control1:  CGPoint(x: cx + halfW * 0.95, y: baseY + height * 0.50),
            control2:  CGPoint(x: cx + halfW * 1.10, y: baseY + height * 0.25))
        // Close across the base
        path.closeSubpath()
        return path
    }

    // MARK: - Steam

    /// Renders steam as stacks of soft overlapping puffs that taper and fade
    /// as they rise. Each puff is a radial-gradient disc — overlapping discs
    /// with low alpha read as a fluffy column of vapor instead of the older
    /// stroked-line look. Hot boiling tints the puffs warm.
    private static func drawSteam(in ctx: CGContext, rect: CGRect, state: IconState) {
        let g = PotGeometry.standard(in: rect)
        let fanIntensity = fanIntensity(state: state)
        let count = steamStrandCount(state: state, fanIntensity: fanIntensity)
        if count == 0 { return }

        // Tint the steam toward warm orange when actively boiling
        let baseTint = lerpColor(
            from: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            to:   CGColor(red: 1.0, green: 0.65, blue: 0.42, alpha: 1.0),
            t:    state.boilingIntensity)

        let baseX = g.centerX
        let stride = rect.width * 0.095
        let bottomY = g.lidApexY + rect.height * 0.035
        let topY = rect.height * (0.93 + 0.05 * fanIntensity)
        let swayMag = stride * (0.55 + 0.55 * fanIntensity)

        let strands: [(CGFloat, CGFloat)] = [
            (baseX,                  0.6),
            (baseX - stride,         1.0),
            (baseX + stride,        -1.0),
            (baseX - stride * 2.0,   1.0),
            (baseX + stride * 2.0,  -1.0)
        ]
        // Per-strand puff size scales with fan intensity so a hot helper
        // visibly produces thicker steam columns.
        let puffRadius = rect.width * (0.065 + 0.030 * fanIntensity)
        for i in 0..<min(count, strands.count) {
            let (x, sway) = strands[i]
            let phaseShift = Double(i) * 0.5 + (state.flameWiggleEnabled ? state.flameWigglePhase * 0.3 : 0)
            drawSteamColumn(
                in: ctx,
                bottomX: x,
                bottomY: bottomY, topY: topY,
                sway: sway,
                amplitude: swayMag,
                phase: phaseShift,
                baseRadius: puffRadius,
                tint: baseTint,
                fanIntensity: fanIntensity)
        }
    }

    /// One vertical column of puffs. Puff count, radius, and alpha all decay
    /// with height so the column fades into the background near the top of
    /// the icon, the way real vapor disperses.
    private static func drawSteamColumn(
        in ctx: CGContext,
        bottomX: CGFloat,
        bottomY: CGFloat, topY: CGFloat,
        sway: CGFloat,
        amplitude: CGFloat,
        phase: Double,
        baseRadius: CGFloat,
        tint: CGColor,
        fanIntensity: Double
    ) {
        let totalHeight = topY - bottomY
        // 6 puffs per column for fuller coverage; each overlaps the previous
        // by ~50% of its radius.
        let puffCount = 6
        let tintComps = tint.components ?? [1, 1, 1, 1]

        for i in 0..<puffCount {
            // 0 at bottom, 1 at top — drives shrink + fade + sway
            let t = CGFloat(i) / CGFloat(puffCount - 1)

            // Radius shrinks gently toward the top so even the top puffs
            // remain visibly chunky rather than tapering to wisps.
            let radius = baseRadius * (1.0 - 0.30 * t)

            // Vertical position with slight uneven spacing — bottom puffs
            // pack tighter, top puffs spread out, mimicking acceleration as
            // the vapor cools and rises faster
            let yFrac = pow(t, 0.85)
            let y = bottomY + totalHeight * yFrac

            // Horizontal sway grows with height; phase keeps neighboring
            // columns out of sync
            let swayOffset = sway * amplitude * t
                + CGFloat(sin(phase + Double(t) * 2.0)) * amplitude * 0.20 * t
            let x = bottomX + swayOffset

            // Alpha decays slowly so even the topmost puff stays visible
            // against the blue background. Fan intensity gives a small extra
            // boost on top.
            let alpha: CGFloat = (1.00 - 0.45 * t) * (0.85 + 0.15 * CGFloat(fanIntensity))

            drawPuff(
                in: ctx,
                center: CGPoint(x: x, y: y),
                radius: radius,
                tintRGB: (tintComps[0], tintComps[1], tintComps[2]),
                alpha: min(1.0, alpha))
        }
    }

    /// One soft puff: radial gradient from `tint+alpha` at the center to
    /// fully transparent at the radius. Drawing many of these at varying
    /// sizes/positions builds up a cloud-like volume.
    private static func drawPuff(
        in ctx: CGContext,
        center: CGPoint,
        radius: CGFloat,
        tintRGB: (CGFloat, CGFloat, CGFloat),
        alpha: CGFloat
    ) {
        guard alpha > 0.01, radius > 0 else { return }
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: tintRGB.0, green: tintRGB.1, blue: tintRGB.2, alpha: alpha),
                CGColor(red: tintRGB.0, green: tintRGB.1, blue: tintRGB.2, alpha: alpha * 0.55),
                CGColor(red: tintRGB.0, green: tintRGB.1, blue: tintRGB.2, alpha: 0.0)
            ] as CFArray,
            locations: [0, 0.55, 1])!
        ctx.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter:   center, endRadius:   radius,
            options: [])
    }

    private static func fanIntensity(state: IconState) -> Double {
        guard let rpm = state.fanRPM else { return 0 }
        return max(0, min(1, (rpm - 1300) / 2200))
    }

    private static func steamStrandCount(state: IconState, fanIntensity: Double) -> Int {
        let usage = state.displayedUsage
        let base: Int
        switch usage {
        case ..<0.1:  base = 1
        case ..<0.5:  base = 2
        case ..<0.85: base = 3
        default:      base = 3
        }
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
