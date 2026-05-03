import Foundation
import os.log

private let log = OSLog(subsystem: "com.macslowcooker", category: "xpc")

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

    /// Establish a one-shot connection, query the helper's CFBundleVersion,
    /// and tear it down. Used to detect stale helper binaries before starting
    /// long-lived sampling. Returns nil on timeout or XPC error.
    static func fetchHelperVersion(timeout: TimeInterval = 2.0) async -> String? {
        let conn = NSXPCConnection(machServiceName: "com.macslowcooker.helper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: MacSlowCookerHelperProtocol.self)
        conn.resume()
        defer { conn.invalidate() }

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                    final class Once { var done = false }
                    let once = Once()
                    let resume: (String?) -> Void = { value in
                        DispatchQueue.main.async {
                            guard !once.done else { return }
                            once.done = true
                            cont.resume(returning: value)
                        }
                    }
                    let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                        resume(nil)
                    } as? MacSlowCookerHelperProtocol
                    if let proxy {
                        proxy.helperVersion { resume($0) }
                    } else {
                        resume(nil)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
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
        let conn = NSXPCConnection(machServiceName: "com.macslowcooker.helper", options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: MacSlowCookerHelperProtocol.self)

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
        } as? MacSlowCookerHelperProtocol

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
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in } as? MacSlowCookerHelperProtocol
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
