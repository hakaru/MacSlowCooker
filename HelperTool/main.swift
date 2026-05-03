import Foundation
import os.log

private let log = OSLog(subsystem: "com.macslowcooker", category: "helper")

// MARK: - Shared service implementation

final class HelperService: NSObject, MacSlowCookerHelperProtocol {
    static let shared = HelperService()

    private let runner = PowerMetricsRunner()
    private let temperatureReader = TemperatureReader()
    private let smcReader = SMCReader()
    private let queue = DispatchQueue(label: "com.macslowcooker.helper.sample")
    private var latestSampleData: Data?
    private var sampling = false

    override init() {
        super.init()
        runner.onSample = { [weak self] sample in
            guard let self else { return }
            let temp = self.temperatureReader.readGPUTemperature()
            let fans = self.smcReader?.readFanRPMs()
            let augmented = GPUSample(
                timestamp: sample.timestamp,
                gpuUsage: sample.gpuUsage,
                temperature: temp ?? sample.temperature,
                thermalPressure: sample.thermalPressure,
                power: sample.power,
                anePower: sample.anePower,
                aneUsage: sample.aneUsage,
                fanRPM: (fans?.isEmpty == false) ? fans : nil
            )
            let data = try? JSONEncoder().encode(augmented)
            self.queue.async { self.latestSampleData = data }
        }
        runner.onError = { message in
            os_log("Runner error: %{public}s", log: log, type: .error, message)
        }
    }

    func startSampling(withReply reply: @escaping (Bool, String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { reply(false, "service deallocated"); return }
            if self.sampling {
                reply(true, nil)
                return
            }
            do {
                try self.runner.start()
                self.sampling = true
                os_log("Sampling started", log: log, type: .info)
                reply(true, nil)
            } catch {
                os_log("Failed to start: %{public}s", log: log, type: .error, error.localizedDescription)
                reply(false, error.localizedDescription)
            }
        }
    }

    func stopSampling(withReply reply: @escaping () -> Void) {
        // Multi-client daemon: keep runner alive while daemon is loaded.
        // launchd will idle the process out when no clients remain connected.
        reply()
    }

    func fetchLatestSample(withReply reply: @escaping (Data?) -> Void) {
        queue.async { [weak self] in reply(self?.latestSampleData) }
    }

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        reply(version)
    }
}

// MARK: - XPC Listener with code signing requirement

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {

    private static let appRequirement =
        "identifier \"com.macslowcooker.app\" and anchor apple generic and certificate leaf[subject.OU] = \"K38MBRNKAT\""

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if #available(macOS 13.0, *) {
            connection.setCodeSigningRequirement(Self.appRequirement)
        }
        connection.exportedInterface = NSXPCInterface(with: MacSlowCookerHelperProtocol.self)
        connection.exportedObject = HelperService.shared
        connection.resume()
        os_log("Accepted XPC connection", log: log, type: .info)
        return true
    }
}

// MARK: - Entry point

let serviceDelegate = ServiceDelegate()
let listener = NSXPCListener(machServiceName: "com.macslowcooker.helper")
listener.delegate = serviceDelegate
listener.resume()
os_log("HelperTool started", log: log, type: .info)
RunLoop.main.run()
