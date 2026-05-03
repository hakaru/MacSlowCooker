import XCTest
@testable import MacSlowCooker

/// `IconState.visualHash` is the dedup key the animator uses to skip redundant
/// `applicationIconImage` assignments. Every assignment is a synchronous
/// WindowServer IPC, so quantizing at coarser-than-pixel resolution lets us
/// collapse imperceptible changes (usage jiggling at ±0.001, fan ±20 RPM)
/// into a single render. These tests pin the quantization buckets so a
/// future tweak that accidentally re-introduces redraw churn is caught.
final class IconStateTests: XCTestCase {

    private func base(
        usage: Double = 0.5,
        temperature: Double? = 60,
        isConnected: Bool = true,
        wigglePhase: Double = 1.0,
        wiggleEnabled: Bool = false,
        isBoiling: Bool = false,
        boilingIntensity: Double = 0,
        fanRPM: Double? = nil
    ) -> IconState {
        IconState(displayedUsage: usage, temperature: temperature,
                  isConnected: isConnected,
                  flameWigglePhase: wigglePhase, flameWiggleEnabled: wiggleEnabled,
                  isBoiling: isBoiling, boilingIntensity: boilingIntensity,
                  fanRPM: fanRPM)
    }

    func testEqualForIdenticalState() {
        XCTAssertEqual(base().visualHash, base().visualHash)
    }

    /// Usage rounds to 0.005 buckets (200 distinct values across [0, 1]).
    func testUsageQuantizedTo005() {
        let a = base(usage: 0.501)
        let b = base(usage: 0.502)
        XCTAssertEqual(a.visualHash, b.visualHash, "0.501 and 0.502 share the 0.005 bucket")

        let c = base(usage: 0.510)
        XCTAssertNotEqual(a.visualHash, c.visualHash, "0.501 vs 0.510 differs by 2 buckets")
    }

    /// Boiling intensity rounds to 0.01 buckets.
    func testBoilingIntensityQuantizedTo01() {
        let a = base(boilingIntensity: 0.501)
        let b = base(boilingIntensity: 0.504)
        XCTAssertEqual(a.visualHash, b.visualHash)

        let c = base(boilingIntensity: 0.512)
        XCTAssertNotEqual(a.visualHash, c.visualHash)
    }

    /// Temperature rounds to whole degrees Celsius. Sub-degree fluctuation
    /// (sensor noise) shouldn't trigger a redraw.
    func testTemperatureQuantizedTo1C() {
        let a = base(temperature: 60.2)
        let b = base(temperature: 60.4)
        XCTAssertEqual(a.visualHash, b.visualHash)

        let c = base(temperature: 61.0)
        XCTAssertNotEqual(a.visualHash, c.visualHash)
    }

    /// Fan RPM rounds to 50 RPM buckets — the implementation uses
    /// `(rpm / 50).rounded()`, so values within ±25 RPM of a multiple of 50
    /// share a hash. 1510 and 1520 both round to 30 (bucket = 1500).
    func testFanRPMQuantizedTo50() {
        let a = base(fanRPM: 1510)
        let b = base(fanRPM: 1520)
        XCTAssertEqual(a.visualHash, b.visualHash, "1510 and 1520 both round to bucket 30 (1500)")

        let c = base(fanRPM: 1600)
        XCTAssertNotEqual(a.visualHash, c.visualHash)
    }

    /// Wiggle phase rounds to 0.05 rad buckets — implementation uses
    /// `(phase * 20).rounded()`, so values within ±0.025 rad of a multiple
    /// of 0.05 share a hash. 1.21 and 1.22 both round to 24 (bucket 1.20).
    func testWigglePhaseQuantizedTo005Rad() {
        let a = base(wigglePhase: 1.21, wiggleEnabled: true)
        let b = base(wigglePhase: 1.22, wiggleEnabled: true)
        XCTAssertEqual(a.visualHash, b.visualHash)

        let c = base(wigglePhase: 1.30, wiggleEnabled: true)
        XCTAssertNotEqual(a.visualHash, c.visualHash)
    }

    /// When wiggle is disabled, phase isn't part of the hash. Without this,
    /// phase advances continuously and would defeat dedup entirely (every
    /// tick produces a new hash, so every tick re-renders).
    func testWigglePhaseIgnoredWhenDisabled() {
        let a = base(wigglePhase: 0.0, wiggleEnabled: false)
        let b = base(wigglePhase: 3.14, wiggleEnabled: false)
        XCTAssertEqual(a.visualHash, b.visualHash)
    }

    func testConnectedVsDisconnectedDiffer() {
        XCTAssertNotEqual(
            base(isConnected: true).visualHash,
            base(isConnected: false).visualHash)
    }

    func testBoilingFlagDifferentiates() {
        let calm = base(isBoiling: false, boilingIntensity: 0.0)
        let active = base(isBoiling: true,  boilingIntensity: 1.0)
        XCTAssertNotEqual(calm.visualHash, active.visualHash)
    }

    /// Nil temperature must not crash the hasher and must collapse to a
    /// single hash regardless of other fields' temperature handling.
    func testNilTemperatureProducesStableHash() {
        let a = base(temperature: nil)
        let b = base(temperature: nil)
        XCTAssertEqual(a.visualHash, b.visualHash)

        let c = base(temperature: 60)
        XCTAssertNotEqual(a.visualHash, c.visualHash, "nil and 60 must differ")
    }

    func testNilFanRPMProducesStableHash() {
        let a = base(fanRPM: nil)
        let b = base(fanRPM: nil)
        XCTAssertEqual(a.visualHash, b.visualHash)

        let c = base(fanRPM: 1500)
        XCTAssertNotEqual(a.visualHash, c.visualHash)
    }
}
