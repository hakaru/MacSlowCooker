import Foundation
import os.log

private let log = OSLog(subsystem: "com.macslowcooker", category: "helper")

final class PowerMetricsRunner {

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var buffer = Data()
    private var failureCount = 0
    private var isStopping = false
    private let maxFailures = 3
    private let restartDelay: TimeInterval = 5.0

    var onSample: ((GPUSample) -> Void)?
    var onError: ((String) -> Void)?

    func start() throws {
        failureCount = 0
        isStopping = false
        try launchProcess()
    }

    func stop() {
        isStopping = true
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        buffer.removeAll()
        os_log("powermetrics stopped", log: log, type: .info)
    }

    private func launchProcess() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        // --show-all is required on macOS 26 to surface processor.ane_power; drop it
        // if/when powermetrics regains that field under the bare ane_power sampler.
        p.arguments = ["--samplers", "gpu_power,ane_power,thermal", "-i", "1000", "--format", "plist", "--show-all"]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        p.terminationHandler = { [weak self] _ in
            guard let self, !self.isStopping else { return }
            os_log("powermetrics terminated unexpectedly", log: log, type: .error)
            self.handleCrash()
        }

        try p.run()
        self.process = p
        self.stdoutPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self.buffer.append(chunk)
            self.flushSamples()
        }

        os_log("powermetrics started (pid: %d)", log: log, type: .info, p.processIdentifier)
    }

    private func handleCrash() {
        failureCount += 1
        if failureCount >= maxFailures {
            os_log("powermetrics failed %d times, giving up", log: log, type: .fault, failureCount)
            onError?("powermetrics crashed \(failureCount) times — GPU monitoring unavailable")
            return
        }
        os_log("powermetrics crash #%d, restarting in 5s", log: log, type: .error, failureCount)
        DispatchQueue.global().asyncAfter(deadline: .now() + restartDelay) { [weak self] in
            guard let self, !self.isStopping else { return }
            do {
                try self.launchProcess()
            } catch {
                os_log("powermetrics restart failed: %{public}s", log: log, type: .fault, error.localizedDescription)
                self.onError?("powermetrics restart failed: \(error.localizedDescription)")
            }
        }
    }

    private func flushSamples() {
        let nul: UInt8 = 0
        while let range = buffer.range(of: Data([nul])) {
            let chunk = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            guard !chunk.isEmpty else { continue }
            if let sample = PowerMetricsParser.parse(plistData: chunk, timestamp: Date()) {
                onSample?(sample)
            }
        }
    }
}
