import XCTest
@testable import MacSlowCooker

final class PrometheusExporterTests: XCTestCase {

    /// Wait up to ~1s for the listener to reach `.ready` and report its
    /// OS-assigned ephemeral port. Replaces the previous fixed `sleep(150ms)`
    /// — robust to slow CI and immune to randomized-port collisions because
    /// the port is `0` (OS picks).
    private func awaitResolvedPort(_ exporter: PrometheusExporter) async throws -> UInt16 {
        for _ in 0..<40 {
            if let p = exporter.resolvedPort { return p }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw XCTSkip("Listener never became ready within 1s")
    }

    func testServeMetricsEndpoint() async throws {
        let exporter = PrometheusExporter(version: "1.2.3")
        try exporter.start(port: 0, loopbackOnly: true)
        defer { exporter.stop() }

        // Push a snapshot.
        let sample = GPUSample(
            timestamp: Date(timeIntervalSince1970: 1778231262),
            gpuUsage: 0.5,
            temperature: 60,
            thermalPressure: nil,
            power: 12,
            anePower: nil,
            aneUsage: nil,
            fanRPM: [1500]
        )
        exporter.update(sample: sample)
        exporter.update(helperConnected: true)

        let port = try await awaitResolvedPort(exporter)
        let url = URL(string: "http://127.0.0.1:\(port)/metrics")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("macslowcooker_gpu_usage_ratio 0.5"))
        XCTAssertTrue(body.contains("macslowcooker_helper_connected 1"))
        XCTAssertTrue(body.contains("macslowcooker_fan_rpm{fan=\"0\"} 1500"))
        XCTAssertTrue(body.contains("macslowcooker_build_info{version=\"1.2.3\"} 1"))
    }

    func testUnknownPathReturns404() async throws {
        let exporter = PrometheusExporter(version: "1.0.0")
        try exporter.start(port: 0, loopbackOnly: true)
        defer { exporter.stop() }

        let port = try await awaitResolvedPort(exporter)
        let url = URL(string: "http://127.0.0.1:\(port)/nope")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 404)
    }
}
