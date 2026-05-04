import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import MacSlowCooker

/// One-shot frame generator for marketing / blog screenshots. Rendered as a
/// test so it has free access to `DutchOvenRenderer`, `IconState`, and the
/// test target's bundled XCUnit infrastructure — but skipped by default to
/// keep CI fast. Touch `/tmp/MACSLOWCOOKER_GENERATE_FRAMES` to enable
/// (sentinel file used because xcodebuild does not propagate shell env into
/// the test runner process).
///
/// Output: `/tmp/macslowcooker-frames/frame_NNN.png` (60 frames, 10 fps).
/// Then build the GIF with:
///
///     ffmpeg -framerate 10 -i /tmp/macslowcooker-frames/frame_%03d.png \
///       -vf "scale=256:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" \
///       -loop 0 /tmp/macslowcooker.gif
///
/// Or MP4:
///
///     ffmpeg -framerate 10 -i /tmp/macslowcooker-frames/frame_%03d.png \
///       -c:v libx264 -pix_fmt yuv420p -movflags +faststart /tmp/macslowcooker.mp4
final class AnimationFrameGeneratorTests: XCTestCase {

    /// 6-second scenario across 60 frames (10 fps):
    /// 0.0–1.0 s: idle (low GPU, cool pot)
    /// 1.0–3.0 s: ramp to full load, temperature rising, fan spins up
    /// 3.0–5.0 s: sustained load → boiling lid bounce kicks in
    /// 5.0–6.0 s: cool down
    func testGenerateAnimationFrames() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "/tmp/MACSLOWCOOKER_GENERATE_FRAMES"),
            "touch /tmp/MACSLOWCOOKER_GENERATE_FRAMES to enable")

        let outDir = URL(fileURLWithPath: "/tmp/macslowcooker-frames")
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let frameCount = 60
        let fps = 10.0
        let dt = 1.0 / fps

        var displayedUsage = 0.0
        var wigglePhase = 0.0
        var boilingIntensity = 0.0
        var aboveThresholdSince: Date? = nil
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)

        // Collect downscaled CGImages so we can also assemble a single GIF
        // without needing ffmpeg / ImageMagick installed.
        var gifFrames: [CGImage] = []
        let gifSide = 256

        for i in 0..<frameCount {
            let t = Double(i) / fps                    // wall-time seconds
            let now = startDate.addingTimeInterval(t)

            // Target usage curve: idle → ramp → hold → cool
            let targetUsage: Double
            switch t {
            case ..<1.0:  targetUsage = 0.05
            case ..<3.0:  targetUsage = 0.05 + (t - 1.0) / 2.0 * 0.90    // ramp 0.05→0.95
            case ..<5.0:  targetUsage = 0.95
            default:      targetUsage = 0.95 - (t - 5.0) / 1.0 * 0.85    // cool 0.95→0.10
            }

            // Temperature follows usage with thermal lag
            let baseTemp = 50.0
            let peakTemp = 92.0
            let temperatureTarget = baseTemp + (peakTemp - baseTemp) * targetUsage
            let temperature = baseTemp + (temperatureTarget - baseTemp) * min(1.0, t / 4.0)

            // Fan RPM follows temperature
            let fanRPM = 1300.0 + (3500.0 - 1300.0) * max(0, min(1, (temperature - 60) / 30))

            // Smooth interpolation toward target (matches DockIconAnimator)
            let alpha = 1 - exp(-dt / 0.7)
            displayedUsage += (targetUsage - displayedUsage) * alpha

            // Wiggle phase advances when usage is visible
            if displayedUsage > 0.05 {
                wigglePhase = (wigglePhase + dt * 4.0).truncatingRemainder(dividingBy: .pi * 2)
            }

            // Boiling rule: sustained 90% for 5s OR thermal pressure (we simulate via sustain only here)
            let highUsage = displayedUsage >= 0.9
            aboveThresholdSince = highUsage ? (aboveThresholdSince ?? now) : nil
            let isBoiling = aboveThresholdSince.map { now.timeIntervalSince($0) >= 5.0 } ?? false
            // Fall back to "boiling once temp >= 85" so the bounce shows up within the 6 s clip
            let isBoilingForDemo = isBoiling || temperature >= 85
            let boilingTarget: Double = isBoilingForDemo ? 1.0 : 0.0
            let beta = 1 - exp(-dt / 0.6)
            boilingIntensity += (boilingTarget - boilingIntensity) * beta

            let state = IconState(
                displayedUsage: displayedUsage,
                temperature: temperature,
                isConnected: true,
                flameWigglePhase: wigglePhase,
                flameWiggleEnabled: true,
                isBoiling: isBoilingForDemo,
                boilingIntensity: boilingIntensity,
                fanRPM: fanRPM)

            let img = DutchOvenRenderer.render(state: state)
            let url = outDir.appendingPathComponent(String(format: "frame_%03d.png", i))
            try savePNG(image: img, to: url)

            if let cg = downscale(image: img, to: gifSide) {
                gifFrames.append(cg)
            }
        }

        // Assemble the GIF natively via ImageIO so the test doesn't depend
        // on ffmpeg or ImageMagick.
        let gifURL = URL(fileURLWithPath: "/tmp/macslowcooker.gif")
        try writeGIF(frames: gifFrames, frameDelay: dt, to: gifURL)

        print("""

        Generated \(frameCount) full-size PNGs at \(outDir.path).
        Generated GIF (\(gifSide)px, \(Int(fps)) fps): \(gifURL.path)

        For an MP4 (requires ffmpeg):
          ffmpeg -y -framerate \(Int(fps)) -i \(outDir.path)/frame_%03d.png \\
            -c:v libx264 -pix_fmt yuv420p -movflags +faststart /tmp/macslowcooker.mp4

        """)
    }

    private func downscale(image: NSImage, to side: Int) -> CGImage? {
        guard let src = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.interpolationQuality = .high
        ctx?.draw(src, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx?.makeImage()
    }

    private func writeGIF(frames: [CGImage], frameDelay: TimeInterval, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil)
        else {
            XCTFail("CGImageDestination create failed")
            return
        }
        let containerProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ] as CFDictionary
        ]
        CGImageDestinationSetProperties(dest, containerProps as CFDictionary)
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay
            ] as CFDictionary
        ]
        for frame in frames {
            CGImageDestinationAddImage(dest, frame, frameProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            XCTFail("CGImageDestination finalize failed")
            return
        }
    }

    private func savePNG(image: NSImage, to url: URL) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("NSImage.cgImage returned nil")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("PNG encoding failed")
            return
        }
        try data.write(to: url)
    }
}
