import Foundation
import os.log

private let log = OSLog(subsystem: "com.macslowcooker", category: "helper")

/// Owns the long-running `/usr/bin/powermetrics` process and turns its
/// NUL-separated plist stream into `GPUSample` callbacks.
///
/// Threading model: every mutation of the runner's internal state
/// (`process`, `stdoutPipe`, `buffer`, `failureCount`, `isStopping`) happens
/// on the private serial `queue`. The `Process.terminationHandler` and
/// `Pipe.readabilityHandler` callbacks Foundation delivers from arbitrary
/// background queues hop onto this queue before touching state. `onSample` is
/// invoked from the queue (callers must tolerate that — `HelperService`
/// already does CPU work + actor hop and is fine with serial dispatch).
final class PowerMetricsRunner {

    private let queue = DispatchQueue(label: "com.macslowcooker.helper.runner")
    private var process: Process?
    private var stdoutPipe: Pipe?
    private let splitter = PlistStreamSplitter()
    private var failureCount = 0
    private var isStopping = false
    private let maxFailures = 3
    private let restartDelay: TimeInterval = 5.0

    var onSample: ((GPUSample) -> Void)?
    var onError: ((String) -> Void)?

    func start() throws {
        var caughtError: Error?
        queue.sync {
            failureCount = 0
            isStopping = false
            do {
                try launchProcessLocked()
            } catch {
                caughtError = error
            }
        }
        if let caughtError { throw caughtError }
    }

    func stop() {
        queue.sync {
            isStopping = true
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            process?.terminate()
            process = nil
            stdoutPipe = nil
            splitter.reset()
        }
        os_log("powermetrics stopped", log: log, type: .info)
    }

    /// Must be called on `queue`.
    private func launchProcessLocked() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        // --show-all is required on macOS 26 to surface processor.ane_power; drop it
        // if/when powermetrics regains that field under the bare ane_power sampler.
        // Intel Macs have no Apple Neural Engine, so the ane_power sampler is
        // dropped and --show-all becomes redundant there.
        #if arch(arm64)
        p.arguments = ["--samplers", "gpu_power,ane_power,thermal", "-i", "1000", "--format", "plist", "--show-all"]
        #else
        p.arguments = ["--samplers", "gpu_power,thermal", "-i", "1000", "--format", "plist"]
        #endif

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        p.terminationHandler = { [weak self] _ in
            // Foundation may invoke this on any thread — hop to our queue
            // before reading isStopping or scheduling a restart.
            guard let self else { return }
            self.queue.async {
                guard !self.isStopping else { return }
                os_log("powermetrics terminated unexpectedly", log: log, type: .error)
                self.handleCrashLocked()
            }
        }

        try p.run()
        self.process = p
        self.stdoutPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // Read off Foundation's queue, but mutate splitter buffer on ours.
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.async {
                guard let self else { return }
                self.flushSamplesLocked(chunk: chunk)
            }
        }

        os_log("powermetrics started (pid: %d)", log: log, type: .info, p.processIdentifier)
    }

    /// Must be called on `queue`.
    private func handleCrashLocked() {
        failureCount += 1
        if failureCount >= maxFailures {
            os_log("powermetrics failed %d times, giving up", log: log, type: .fault, failureCount)
            onError?("powermetrics crashed \(failureCount) times — GPU monitoring unavailable")
            return
        }
        os_log("powermetrics crash #%d, restarting in 5s", log: log, type: .error, failureCount)
        queue.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
            guard let self, !self.isStopping else { return }
            do {
                try self.launchProcessLocked()
            } catch {
                os_log("powermetrics restart failed: %{public}s", log: log, type: .fault, error.localizedDescription)
                self.onError?("powermetrics restart failed: \(error.localizedDescription)")
            }
        }
    }

    /// Must be called on `queue`. Feeds the new chunk into the splitter and
    /// emits a sample for each complete plist payload.
    private func flushSamplesLocked(chunk: Data) {
        for plist in splitter.append(chunk) {
            if let sample = PowerMetricsParser.parse(plistData: plist, timestamp: Date()) {
                onSample?(sample)
            }
        }
    }
}
