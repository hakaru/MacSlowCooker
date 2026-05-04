import Foundation
import Network
import os

/// HTTP/1.1 server exposing `GET /metrics` in Prometheus text exposition
/// format. Not thread-safe across instances; mutable state inside one
/// instance is serialized through a private dispatch queue.
final class PrometheusExporter {
    private let version: String
    private let log = OSLog(subsystem: "com.macslowcooker.app", category: "PrometheusExporter")
    private let queue = DispatchQueue(label: "com.macslowcooker.prometheus-exporter")

    private var listener: NWListener?
    private var latestSample: GPUSample?
    private var helperConnected: Bool = false
    private var _resolvedPort: UInt16?

    /// Actual bound port. Populated when the listener reaches `.ready`. Useful
    /// for tests that pass `port: 0` to let the OS pick an ephemeral port.
    var resolvedPort: UInt16? { queue.sync { _resolvedPort } }

    init(version: String) { self.version = version }

    deinit { listener?.cancel() }

    /// Start listening on `port` (pass `0` to let the OS pick an ephemeral
    /// port; read it back from `resolvedPort` once ready). If `loopbackOnly`
    /// is true the listener binds only to the loopback interface (no firewall
    /// prompt; only reachable from the same Mac).
    func start(port: UInt16, loopbackOnly: Bool) throws {
        // Stop any previous listener first.
        stop()

        let params = NWParameters.tcp
        // Allow rebinding the same port immediately after a previous bind,
        // including the TIME_WAIT window left behind by SIGKILL or a crash.
        params.allowLocalEndpointReuse = true
        if loopbackOnly { params.requiredInterfaceType = .loopback }
        // Disable IPv6 on loopback to keep the URL stable (`127.0.0.1`)
        // — Prometheus scrape configs typically use the IPv4 form.
        if loopbackOnly {
            if let ipOpt = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOpt.version = .v4
            }
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "PrometheusExporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let actual = self.listener?.port?.rawValue ?? port
                self._resolvedPort = actual
                os_log("Prometheus listener ready on %d", log: self.log, type: .info, Int(actual))
            case .failed(let err):
                self._resolvedPort = nil
                os_log("Prometheus listener failed: %{public}@", log: self.log, type: .error, "\(err)")
            case .cancelled:
                self._resolvedPort = nil
            default:
                break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in self?._resolvedPort = nil }
    }

    func update(sample: GPUSample?) {
        queue.async { [weak self] in self?.latestSample = sample }
    }

    func update(helperConnected: Bool) {
        queue.async { [weak self] in self?.helperConnected = helperConnected }
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { conn.cancel(); return }
            if let error {
                os_log("recv error: %{public}@", log: self.log, type: .info, "\(error)")
                conn.cancel(); return
            }
            let path = data.flatMap(Self.parseRequestPath) ?? ""
            let response: Data = self.makeResponse(forPath: path)
            conn.send(content: response, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    /// Extract the request-target from the start-line of an HTTP/1.x request.
    /// Returns nil for malformed input. Cap at 1024 bytes — request lines
    /// longer than that are spam.
    static func parseRequestPath(in data: Data) -> String? {
        guard let crlf = data.firstRange(of: Data([0x0d, 0x0a])) else { return nil }
        let line = data[..<crlf.lowerBound]
        guard line.count <= 1024,
              let str = String(data: line, encoding: .utf8) else { return nil }
        let parts = str.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    private func makeResponse(forPath path: String) -> Data {
        // `latestSample` and `helperConnected` are only accessed on `queue`,
        // and `handle(_:)` is called from `queue`, so direct reads are safe.
        if path == "/metrics" {
            let body = PrometheusFormatter.exposition(
                sample: latestSample,
                helperConnected: helperConnected,
                version: version
            )
            return Self.makeHTTP(status: "200 OK",
                                  contentType: "text/plain; version=0.0.4; charset=utf-8",
                                  body: body)
        }
        return Self.makeHTTP(status: "404 Not Found",
                              contentType: "text/plain; charset=utf-8",
                              body: "Not Found\n")
    }

    private static func makeHTTP(status: String, contentType: String, body: String) -> Data {
        var head = ""
        head += "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        let bodyData = body.data(using: .utf8) ?? Data()
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data()
        out.append(head.data(using: .utf8) ?? Data())
        out.append(bodyData)
        return out
    }
}
