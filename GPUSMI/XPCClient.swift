import Foundation
import os.log

private let log = OSLog(subsystem: "com.gpusmi", category: "xpc")

@MainActor
final class XPCClient {

    private var connection: NSXPCConnection?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 30.0
    private var samplingTimer: Timer?

    var onSample: ((GPUSample) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    func connect() {
        guard connection == nil else { return }
        makeConnection()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        samplingTimer?.invalidate()
        samplingTimer = nil
        connection?.invalidate()
        connection = nil
        reconnectDelay = 1.0
    }

    private func makeConnection() {
        let conn = NSXPCConnection(machServiceName: "com.gpusmi.helper", options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: GPUSMIHelperProtocol.self)

        conn.interruptionHandler = { [weak self] in
            os_log("XPC interrupted, reconnecting immediately...", log: log, type: .info)
            Task { @MainActor [weak self] in
                self?.connection = nil
                self?.handleDisconnection()
                self?.makeConnection()
            }
        }

        conn.invalidationHandler = { [weak self] in
            os_log("XPC invalidated", log: log, type: .error)
            Task { @MainActor [weak self] in
                self?.connection = nil
                self?.handleDisconnection()
                self?.scheduleReconnect()
            }
        }

        conn.resume()
        connection = conn

        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            os_log("XPC error: %{public}s", log: log, type: .error, error.localizedDescription)
        } as? GPUSMIHelperProtocol

        proxy?.startSampling { [weak self] success, errorMessage in
            Task { @MainActor [weak self] in
                if success {
                    os_log("Sampling started", log: log, type: .info)
                    self?.reconnectDelay = 1.0
                    self?.onConnected?()
                    self?.startPollingTimer()
                } else {
                    os_log("Start failed: %{public}s", log: log, type: .error, errorMessage ?? "unknown")
                    self?.scheduleReconnect()
                }
            }
        }
    }

    private func startPollingTimer() {
        samplingTimer?.invalidate()
        samplingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchSample()
            }
        }
    }

    private func fetchSample() {
        guard let conn = connection else { return }
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in } as? GPUSMIHelperProtocol
        proxy?.fetchLatestSample { [weak self] data in
            guard let data else { return }
            Task { @MainActor [weak self] in
                if let sample = try? JSONDecoder().decode(GPUSample.self, from: data) {
                    self?.onSample?(sample)
                }
            }
        }
    }

    private func handleDisconnection() {
        samplingTimer?.invalidate()
        samplingTimer = nil
        onDisconnected?()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        os_log("Reconnecting in %.0fs", log: log, type: .info, delay)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.makeConnection()
            }
        }
    }
}
