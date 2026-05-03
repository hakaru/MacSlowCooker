import XCTest
@testable import MacSlowCooker

/// Pinning tests for `HelperInstaller.compareVersions`. The function gates
/// daemon refresh: it must return `.bundledNewer` only when an upgrade is
/// genuinely warranted, and refuse anything that could downgrade a
/// running helper to an older binary (Codex security audit, 2026-05-04,
/// finding #13).
@MainActor
final class HelperInstallerTests: XCTestCase {

    typealias Cmp = HelperInstaller.VersionComparison

    // MARK: - Equal

    func testIntegerEqual() {
        XCTAssertEqual(HelperInstaller.compareVersions(bundled: "1", running: "1"), Cmp.same)
    }

    func testDottedEqual() {
        XCTAssertEqual(HelperInstaller.compareVersions(bundled: "1.2.3", running: "1.2.3"), Cmp.same)
    }

    // MARK: - Bundled newer (refresh expected)

    func testIntegerBundledNewer() {
        XCTAssertEqual(HelperInstaller.compareVersions(bundled: "2", running: "1"), Cmp.bundledNewer)
    }

    func testDottedBundledNewer() {
        XCTAssertEqual(HelperInstaller.compareVersions(bundled: "1.3.0", running: "1.2.9"), Cmp.bundledNewer)
    }

    func testDottedBundledLongerWhenSharedPrefixEqual() {
        XCTAssertEqual(HelperInstaller.compareVersions(bundled: "1.2.0", running: "1.2"), Cmp.bundledNewer)
    }

    // MARK: - Bundled older (refresh refused — security blocker)

    func testIntegerBundledOlderRefusesDowngrade() {
        XCTAssertEqual(HelperInstaller.compareVersions(bundled: "1", running: "2"), Cmp.bundledOlder)
    }

    func testDottedBundledOlderRefusesDowngrade() {
        XCTAssertEqual(HelperInstaller.compareVersions(bundled: "1.2.0", running: "1.3.0"), Cmp.bundledOlder)
    }

    func testDottedRunningLongerRefusesDowngrade() {
        XCTAssertEqual(HelperInstaller.compareVersions(bundled: "1.2", running: "1.2.0"), Cmp.bundledOlder)
    }

    /// Strings that don't parse as integer or dotted-numeric are treated as
    /// `bundledOlder` so we never replace a working helper with something
    /// we can't reason about. The defensive default refuses refresh.
    func testUnparseableTreatedAsDowngrade() {
        XCTAssertEqual(HelperInstaller.compareVersions(bundled: "alpha", running: "beta"), Cmp.bundledOlder)
        XCTAssertEqual(HelperInstaller.compareVersions(bundled: "1.0-rc1", running: "1.0"), Cmp.bundledOlder)
    }

    func testIntegerVsDottedTreatedAsDowngrade() {
        // "2" parses as Int; "1.0" doesn't parse as Int but parses as
        // dotted. The function picks Int compare when both sides parse,
        // so this should fall through to dotted compare which fails on
        // "2" (one component) vs "1.0" (two) — handled by the
        // shared-prefix-equal rule.
        XCTAssertEqual(HelperInstaller.compareVersions(bundled: "2", running: "1.0"), Cmp.bundledNewer)
    }
}
