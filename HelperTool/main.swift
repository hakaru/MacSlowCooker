import Foundation
import os.log

private let log = OSLog(subsystem: "com.gpusmi", category: "helper")

// MARK: - XPC Service implementation

final class HelperService: NSObject, GPUSMIHelperProtocol {
    private let runner = PowerMetricsRunner()
    private var latestSampleData: Data?

    override init() {
        super.init()
        runner.onSample = { [weak self] sample in
            self?.latestSampleData = try? JSONEncoder().encode(sample)
        }
        runner.onError = { message in
            os_log("Runner error: %{public}s", log: log, type: .error, message)
        }
    }

    func startSampling(withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            try runner.start()
            os_log("Sampling started", log: log, type: .info)
            reply(true, nil)
        } catch {
            os_log("Failed to start: %{public}s", log: log, type: .error, error.localizedDescription)
            reply(false, error.localizedDescription)
        }
    }

    func stopSampling(withReply reply: @escaping () -> Void) {
        runner.stop()
        reply()
    }

    func fetchLatestSample(withReply reply: @escaping (Data?) -> Void) {
        reply(latestSampleData)
    }

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        reply(version)
    }
}

// MARK: - XPC Listener

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // In production this would verify the caller's Team ID via auditToken + SecCode.
        // For development without code signing, accept all connections.
        connection.exportedInterface = NSXPCInterface(with: GPUSMIHelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        os_log("Accepted XPC connection", log: log, type: .info)
        return true
    }
}

// MARK: - Entry point

let serviceDelegate = ServiceDelegate()
let listener = NSXPCListener(machServiceName: "com.gpusmi.helper")
listener.delegate = serviceDelegate
listener.resume()
os_log("HelperTool started", log: log, type: .info)
RunLoop.main.run()
