import Foundation
import os.log

private let log = OSLog(subsystem: "com.macslowcooker", category: "helper")

// MARK: - Shared service implementation

/// Mutable helper state isolated by Swift Actor instead of a serial DispatchQueue.
/// Eliminates the data-race risk that strict-concurrency mode flags on the
/// previous queue-protected design — actor isolation enforces single-threaded
/// access to `sampling` and `latestSampleData` at the type system level.
///
/// Three-phase lifecycle:
///   - .idle      — no powermetrics process; first caller transitions to .starting
///   - .starting  — leader is running runner.start(); subsequent callers wait
///                  on a continuation, then receive the same outcome
///   - .running   — sampling is live; subsequent callers short-circuit success
///
/// The phase + waiter queue closes the race that pure boolean
/// tryBeginSampling left open: previously a follower replied "(true, nil)"
/// to its client immediately, so if the leader's runner.start() then threw,
/// the follower's app proceeded believing the helper was active when it
/// wasn't (Gemini security audit, 2026-05-04, finding #26).
private actor HelperState {
    enum Phase { case idle, starting, running }
    enum StartRole { case leader, follower, alreadyRunning }

    private var phase: Phase = .idle
    private var startWaiters: [CheckedContinuation<Bool, Never>] = []
    private var latestSampleData: Data?

    /// Atomically claim the leader role or queue as a follower.
    /// Followers must call `awaitStartOutcome()` next; leaders must call
    /// `completeStart(success:)` once `runner.start()` has resolved.
    func acquireStartRole() -> StartRole {
        switch phase {
        case .idle:
            phase = .starting
            return .leader
        case .starting:
            return .follower
        case .running:
            return .alreadyRunning
        }
    }

    /// Block the follower's Task until the leader publishes the outcome.
    /// Returns true if sampling is now live, false if the leader's
    /// runner.start() threw.
    func awaitStartOutcome() async -> Bool {
        await withCheckedContinuation { cont in
            startWaiters.append(cont)
        }
    }

    /// Leader resolves the start: flips the phase, then resumes any
    /// followers queued during the .starting window with the same outcome.
    func completeStart(success: Bool) {
        phase = success ? .running : .idle
        let waiters = startWaiters
        startWaiters.removeAll()
        for w in waiters { w.resume(returning: success) }
    }

    func setLatestSample(_ data: Data?) { latestSampleData = data }
    func latestSample() -> Data? { latestSampleData }
}

final class HelperService: NSObject, MacSlowCookerHelperProtocol {
    static let shared = HelperService()

    private let runner = PowerMetricsRunner()
    private let temperatureReader = TemperatureReader()
    private let smcReader = SMCReader()
    private let ioaReader = IOAcceleratorReader()
    private let state = HelperState()

    override init() {
        super.init()
        runner.onSample = { [weak self] sample in
            guard let self else { return }
            // Reading sensors is a blocking IOKit call; stay on the runner's
            // queue rather than hopping into the actor for it. Only the actor
            // write needs isolation.
            let augmented = self.augment(powerSample: sample)
            let data = try? JSONEncoder().encode(augmented)
            Task { [weak self] in
                await self?.state.setLatestSample(data)
            }
        }
        runner.onError = { message in
            os_log("Runner error: %{public}s", log: log, type: .error, message)
        }
    }

    private func augment(powerSample sample: GPUSample) -> GPUSample {
        let temp = temperatureReader.readGPUTemperature()
        let fans = smcReader?.readFanRPMs()
        // Prefer IOAccelerator's Device Utilization % (matches Activity Monitor).
        // Fall back to powermetrics' idle_ratio derivation if IOKit read fails.
        let usage = ioaReader.readGPUUsage() ?? sample.gpuUsage
        return GPUSample(
            timestamp: sample.timestamp,
            gpuUsage: usage,
            temperature: temp ?? sample.temperature,
            thermalPressure: sample.thermalPressure,
            power: sample.power,
            anePower: sample.anePower,
            aneUsage: sample.aneUsage,
            fanRPM: (fans?.isEmpty == false) ? fans : nil
        )
    }

    func startSampling(withReply reply: @escaping (Bool, String?) -> Void) {
        Task { [weak self] in
            guard let self else { reply(false, "service deallocated"); return }
            switch await self.state.acquireStartRole() {
            case .alreadyRunning:
                // Sampling is already live; idempotent success.
                reply(true, nil)

            case .follower:
                // Another caller is in the middle of starting. Wait for the
                // leader's outcome and reply with the same answer so the two
                // clients can't disagree about whether the helper is alive.
                let success = await self.state.awaitStartOutcome()
                reply(success, success ? nil : "leader's runner.start() failed")

            case .leader:
                do {
                    try self.runner.start()
                    // Powermetrics takes ~1.3 s to emit its first plist after spawn,
                    // and the app polls fetchLatestSample at 2 Hz. Without a primer,
                    // the popup shows "--" for 2–3 s after every cold launch. Build
                    // a sample from IOAccelerator + SMC + temp readers (everything
                    // except powermetrics-derived power) so the popup fills within
                    // the first poll. Power fills in once powermetrics catches up.
                    if let primer = self.makeIOKitOnlySample(),
                       let data = try? JSONEncoder().encode(primer) {
                        await self.state.setLatestSample(data)
                    }
                    os_log("Sampling started", log: log, type: .info)
                    await self.state.completeStart(success: true)
                    reply(true, nil)
                } catch {
                    // runner.start() failed: roll the phase back to .idle
                    // and propagate the failure to every queued follower
                    // so they don't proceed thinking the helper is alive.
                    await self.state.completeStart(success: false)
                    os_log("Failed to start: %{public}s", log: log, type: .error, error.localizedDescription)
                    reply(false, error.localizedDescription)
                }
            }
        }
    }

    /// Synthesize a GPUSample from in-process IOKit/SMC sources without waiting
    /// for a powermetrics plist. Requires a real GPU usage reading: emitting a
    /// primer with `gpuUsage: 0` would show the user a misleading "idle" GPU
    /// for ~1 s on cold launch even when the GPU is busy. Returns nil when
    /// IOAccelerator is unreadable so the caller waits for powermetrics
    /// instead.
    private func makeIOKitOnlySample() -> GPUSample? {
        guard let usage = ioaReader.readGPUUsage() else { return nil }
        let temp = temperatureReader.readGPUTemperature()
        let fans = smcReader?.readFanRPMs()
        return GPUSample(
            timestamp: Date(),
            gpuUsage: usage,
            temperature: temp,
            thermalPressure: nil,
            power: nil,
            anePower: nil,
            aneUsage: nil,
            fanRPM: (fans?.isEmpty == false) ? fans : nil
        )
    }

    func stopSampling(withReply reply: @escaping () -> Void) {
        // Intentional no-op. See `MacSlowCookerHelperProtocol.stopSampling`
        // for the lifecycle rationale.
        reply()
    }

    func fetchLatestSample(withReply reply: @escaping (Data?) -> Void) {
        Task { [weak self] in
            let data = await self?.state.latestSample()
            reply(data)
        }
    }

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        reply(version)
    }
}

// MARK: - XPC Listener with code signing requirement

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if #available(macOS 13.0, *) {
            connection.setCodeSigningRequirement(CodeSigningConfig.xpcClientRequirement)
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
