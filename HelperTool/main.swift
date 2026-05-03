import Foundation
import os.log

private let log = OSLog(subsystem: "com.macslowcooker", category: "helper")

// MARK: - Shared service implementation

final class HelperService: NSObject, MacSlowCookerHelperProtocol {
    static let shared = HelperService()

    private let runner = PowerMetricsRunner()
    private let temperatureReader = TemperatureReader()
    private let smcReader = SMCReader()
    private let ioaReader = IOAcceleratorReader()
    private let queue = DispatchQueue(label: "com.macslowcooker.helper.sample")
    private var latestSampleData: Data?
    private var sampling = false

    override init() {
        super.init()
        runner.onSample = { [weak self] sample in
            guard let self else { return }
            let temp = self.temperatureReader.readGPUTemperature()
            let fans = self.smcReader?.readFanRPMs()
            // Prefer IOAccelerator's Device Utilization % (matches Activity Monitor).
            // Fall back to powermetrics' idle_ratio derivation if IOKit read fails.
            let usage = self.ioaReader.readGPUUsage() ?? sample.gpuUsage
            let augmented = GPUSample(
                timestamp: sample.timestamp,
                gpuUsage: usage,
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
                // Powermetrics takes ~1.3 s to emit its first plist after spawn,
                // and the app polls fetchLatestSample at 2 Hz. Without a primer,
                // the popup shows "--" for 2–3 s after every cold launch. Build
                // a sample from IOAccelerator + SMC + temp readers (everything
                // except powermetrics-derived power) so the popup fills within
                // the first poll. Power fills in once powermetrics catches up.
                if let primer = self.makeIOKitOnlySample(), let data = try? JSONEncoder().encode(primer) {
                    self.latestSampleData = data
                }
                os_log("Sampling started", log: log, type: .info)
                reply(true, nil)
            } catch {
                os_log("Failed to start: %{public}s", log: log, type: .error, error.localizedDescription)
                reply(false, error.localizedDescription)
            }
        }
    }

    /// Synthesize a GPUSample from in-process IOKit/SMC sources without waiting
    /// for a powermetrics plist. Returns nil if every source failed (no GPU
    /// utilization, no temp, no fan), in which case the caller leaves the
    /// existing latestSampleData alone.
    private func makeIOKitOnlySample() -> GPUSample? {
        let usage = ioaReader.readGPUUsage()
        let temp = temperatureReader.readGPUTemperature()
        let fans = smcReader?.readFanRPMs()
        guard usage != nil || temp != nil || (fans?.isEmpty == false) else { return nil }
        return GPUSample(
            timestamp: Date(),
            gpuUsage: usage ?? 0,
            temperature: temp,
            thermalPressure: nil,
            power: nil,
            anePower: nil,
            aneUsage: nil,
            fanRPM: (fans?.isEmpty == false) ? fans : nil
        )
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
