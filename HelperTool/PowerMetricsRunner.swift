import Foundation
import os.log

private let log = OSLog(subsystem: "com.gpusmi", category: "helper")

final class PowerMetricsRunner {

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var buffer = Data()
    var onSample: ((GPUSample) -> Void)?
    var onError: ((String) -> Void)?

    func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        p.arguments = ["--samplers", "gpu_power,ane_power,thermal", "-i", "1000", "--format", "plist"]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        p.terminationHandler = { [weak self] _ in
            os_log("powermetrics terminated", log: log, type: .error)
            self?.onError?("powermetrics process terminated unexpectedly")
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

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        buffer.removeAll()
        os_log("powermetrics stopped", log: log, type: .info)
    }

    private func flushSamples() {
        let nul: UInt8 = 0
        while let range = buffer.range(of: Data([nul])) {
            let chunk = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            guard !chunk.isEmpty else { continue }
            if let sample = PowerMetricsParser.parse(plistData: chunk, timestamp: Date()) {
                onSample?(sample)
            } else {
                os_log("Failed to parse plist chunk (%d bytes)", log: log, type: .debug, chunk.count)
            }
        }
    }
}
