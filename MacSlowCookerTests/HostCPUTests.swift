import XCTest
@testable import MacSlowCooker

final class HostCPUTests: XCTestCase {

    /// Smoke check: the lookup must not crash and must return a stable
    /// value (the property is `let`-initialized via a closure).
    func testIsAppleSiliconReturnsStableValue() {
        let first = HostCPU.isAppleSilicon
        let second = HostCPU.isAppleSilicon
        XCTAssertEqual(first, second)
    }

    /// On the developer's hardware (Mac Studio M3 Ultra) the result must
    /// be true. CI on Apple Silicon hosts will agree; CI on Intel runners
    /// will return false. Either way, the value must match the host arch
    /// of the test process — `#if arch(arm64)` reflects the slice the test
    /// runner is executing, which equals the host arch when not under
    /// translation. (Test runners normally run native, so this holds.)
    func testIsAppleSiliconMatchesHostArchInNativeRun() {
        #if arch(arm64)
        XCTAssertTrue(HostCPU.isAppleSilicon,
                      "Test runner is arm64 — host should be Apple Silicon")
        #else
        XCTAssertFalse(HostCPU.isAppleSilicon,
                       "Test runner is x86_64 — host should be Intel (or test should be re-running under Rosetta, which is unusual for CI)")
        #endif
    }
}
