import XCTest
@testable import MacSlowCooker

final class PowerMetricsParserTests: XCTestCase {

    func testParsePlistData() throws {
        let dict: [String: Any] = [
            "GPU": [
                "gpu_active_residency": 0.68,
                "gpu_power_mW": 8200.0
            ] as [String: Any],
            "ANE": [
                "ane_active_residency": 0.12
            ] as [String: Any],
            "thermal_pressure": "Nominal"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = PowerMetricsParser.parse(plistData: plistData, timestamp: Date(timeIntervalSince1970: 1000))

        XCTAssertNotNil(sample)
        XCTAssertEqual(try XCTUnwrap(sample?.gpuUsage), 0.68, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sample?.power), 8.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sample?.aneUsage), 0.12, accuracy: 0.001)
    }

    /// The pot-icon-poc parser still requires a parseable GPU usage value
    /// to emit a sample — thermal_pressure alone is not enough. (main's
    /// Optional gpuUsage refactor was not adopted on this branch; see PR
    /// description for rationale.)
    func testParseMissingGPUReturnsNil() throws {
        let dict: [String: Any] = ["thermal_pressure": "Nominal"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = PowerMetricsParser.parse(plistData: plistData, timestamp: Date())

        XCTAssertNil(sample)
    }

    func testParseEmptyDictReturnsNil() throws {
        let dict: [String: Any] = [:]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = PowerMetricsParser.parse(plistData: plistData, timestamp: Date())

        XCTAssertNil(sample)
    }

    func testParseNilOptionalFields() throws {
        let dict: [String: Any] = [
            "GPU": ["gpu_active_residency": 0.5] as [String: Any]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = PowerMetricsParser.parse(plistData: plistData, timestamp: Date())

        XCTAssertNotNil(sample)
        XCTAssertEqual(try XCTUnwrap(sample?.gpuUsage), 0.5, accuracy: 0.001)
        XCTAssertNil(sample?.temperature)
        XCTAssertNil(sample?.power)
        XCTAssertNil(sample?.aneUsage)
    }

    // (Intel gpu_busy / busy_ns coverage lives in the "Intel powermetrics
    // schema" section below — the duplicate testParseGpuBusyKey /
    // testParseBusyNsKey from origin/main were removed during the merge.)

    // MARK: - macOS 26 (Tahoe) schema

    /// macOS 26 powermetrics emits lowercase "gpu" with "idle_ratio" instead of
    /// "gpu_active_residency". gpuUsage is derived as 1 - idle_ratio.
    func testParseTahoeIdleRatio() throws {
        let dict: [String: Any] = [
            "gpu": ["idle_ratio": 0.32] as [String: Any]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = try XCTUnwrap(PowerMetricsParser.parse(plistData: plistData, timestamp: Date()))

        XCTAssertEqual(sample.gpuUsage, 0.68, accuracy: 0.001)
    }

    /// macOS 26 dropped gpu_power_mW. Power is derived from gpu_energy (mJ over
    /// the elapsed window) divided by elapsed_ns converted to seconds.
    /// 5000 mJ over 1e9 ns = 5 J / 1 s = 5 W.
    func testParseTahoeGPUEnergyDerivesPower() throws {
        let dict: [String: Any] = [
            "gpu": [
                "idle_ratio": 0.5,
                "gpu_energy": 5000.0
            ] as [String: Any],
            "elapsed_ns": 1_000_000_000.0
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = try XCTUnwrap(PowerMetricsParser.parse(plistData: plistData, timestamp: Date()))

        XCTAssertEqual(try XCTUnwrap(sample.power), 5.0, accuracy: 0.001)
    }

    /// macOS 26 ANE power lives at processor.ane_power (mW), not under "ane".
    func testParseTahoeProcessorAnePower() throws {
        let dict: [String: Any] = [
            "gpu": ["idle_ratio": 0.0] as [String: Any],
            "processor": ["ane_power": 850.0] as [String: Any]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = try XCTUnwrap(PowerMetricsParser.parse(plistData: plistData, timestamp: Date()))

        XCTAssertEqual(try XCTUnwrap(sample.anePower), 0.85, accuracy: 0.001)
    }

    /// thermal_pressure is the only thermal signal exposed on macOS 26 (no
    /// gpu_die_temperature). Verify it round-trips into GPUSample.
    func testParseTahoeThermalPressure() throws {
        let dict: [String: Any] = [
            "gpu": ["idle_ratio": 0.7] as [String: Any],
            "thermal_pressure": "Serious"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = try XCTUnwrap(PowerMetricsParser.parse(plistData: plistData, timestamp: Date()))

        XCTAssertEqual(sample.thermalPressure, .serious)
        XCTAssertNil(sample.temperature)   // not exposed on macOS 26
    }

    /// powermetrics has historically capitalized the thermal_pressure value
    /// ("Nominal", "Fair", "Serious", "Critical"), but a future macOS could
    /// switch the casing or emit a trailing newline. The parser uses the
    /// lenient enum init so neither variation silently disables the
    /// combined boiling trigger.
    func testThermalPressureLenientParsingIsCaseInsensitive() throws {
        for raw in ["nominal", "NOMINAL", "Nominal", "  Nominal  ", "Nominal\n"] {
            let dict: [String: Any] = [
                "gpu": ["idle_ratio": 0.7] as [String: Any],
                "thermal_pressure": raw
            ]
            let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
            let sample = try XCTUnwrap(PowerMetricsParser.parse(plistData: plistData, timestamp: Date()))
            XCTAssertEqual(sample.thermalPressure, .nominal,
                           "raw '\(raw)' should map to .nominal")
        }
    }

    /// Truly unknown values still surface as nil — the lenient init must
    /// not guess.
    func testThermalPressureUnknownStringReturnsNil() throws {
        let dict: [String: Any] = [
            "gpu": ["idle_ratio": 0.7] as [String: Any],
            "thermal_pressure": "Heavy"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        let sample = try XCTUnwrap(PowerMetricsParser.parse(plistData: plistData, timestamp: Date()))
        XCTAssertNil(sample.thermalPressure)
    }

    // MARK: - Intel powermetrics schema

    /// Intel Macs running powermetrics emit gpu_busy as integer percent.
    func testParseIntelGpuBusy() throws {
        let dict: [String: Any] = [
            "gpu": ["gpu_busy": 42.5] as [String: Any]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = try XCTUnwrap(PowerMetricsParser.parse(plistData: plistData, timestamp: Date()))

        XCTAssertEqual(sample.gpuUsage, 0.425, accuracy: 0.001)
    }

    /// Intel discrete-GPU samples (rdar/AMD path) carry busy_ns + elapsed_ns
    /// inside the gpu dict instead of at the top level.
    func testParseIntelBusyNsInGpuDict() throws {
        let dict: [String: Any] = [
            "gpu": [
                "busy_ns": 750_000_000.0,
                "elapsed_ns": 1_000_000_000.0
            ] as [String: Any]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = try XCTUnwrap(PowerMetricsParser.parse(plistData: plistData, timestamp: Date()))

        XCTAssertEqual(sample.gpuUsage, 0.75, accuracy: 0.001)
    }

    /// busy_ns inside the gpu dict + elapsed_ns at top level — older Intel layouts.
    func testParseIntelBusyNsTopLevelElapsed() throws {
        let dict: [String: Any] = [
            "gpu": ["busy_ns": 250_000_000.0] as [String: Any],
            "elapsed_ns": 1_000_000_000.0
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = try XCTUnwrap(PowerMetricsParser.parse(plistData: plistData, timestamp: Date()))

        XCTAssertEqual(sample.gpuUsage, 0.25, accuracy: 0.001)
    }

    /// Full Tahoe-shaped plist exercising all four fields the parser produces
    /// on macOS 26. Mimics what /usr/bin/powermetrics --samplers
    /// gpu_power,ane_power,thermal --show-all emits on M3 Ultra.
    func testParseFullTahoeSample() throws {
        let dict: [String: Any] = [
            "gpu": [
                "idle_ratio": 0.25,        // 75% busy
                "gpu_energy": 12_000.0     // 12 J over the window
            ] as [String: Any],
            "processor": [
                "ane_power": 320.0         // 0.32 W
            ] as [String: Any],
            "elapsed_ns": 1_000_000_000.0, // 1 s window
            "thermal_pressure": "Fair"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = try XCTUnwrap(PowerMetricsParser.parse(plistData: plistData, timestamp: Date()))

        XCTAssertEqual(sample.gpuUsage, 0.75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sample.power), 12.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sample.anePower), 0.32, accuracy: 0.001)
        XCTAssertEqual(sample.thermalPressure, .fair)
        XCTAssertNil(sample.temperature)
    }
}
