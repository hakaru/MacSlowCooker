import Foundation
import IOKit
import os.log

private let ioaLog = OSLog(subsystem: "com.macslowcooker", category: "ioaccel")

/// Reads GPU utilization from `IOAccelerator`'s `PerformanceStatistics` dictionary,
/// which is the same source Activity Monitor uses for its "GPU History" graph.
///
/// Pure selection logic (sort by name, take first usable) lives in
/// `IOAcceleratorSelection` so it can be unit-tested. This class wraps the
/// IOKit iteration and per-service property reads.
final class IOAcceleratorReader {

    private let lock = NSLock()
    private var hasLogged = false

    /// Returns GPU utilization in [0, 1], or nil if the IOAccelerator service
    /// isn't readable.
    func readGPUUsage() -> Double? {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator)
        guard kr == KERN_SUCCESS else {
            os_log("IOServiceGetMatchingServices failed: %x", log: ioaLog, type: .error, kr)
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var readings: [IOAcceleratorSelection.Reading] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            readings.append(makeReading(service: service))
        }

        guard let result = IOAcceleratorSelection.aggregate(from: readings) else {
            // Still log services on first read even when no usable percentage,
            // so the user can see why the icon stays disconnected.
            logServicesIfFirstRead(readings.sorted { $0.name < $1.name }, contributingCount: 0)
            return nil
        }

        logServicesIfFirstRead(result.sortedReadings, contributingCount: result.contributingCount)
        return IOAcceleratorSelection.normalize(percent: result.utilization)
    }

    private func makeReading(service: io_object_t) -> IOAcceleratorSelection.Reading {
        var nameBuf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(service, &nameBuf)
        let name = String(cString: nameBuf)

        var classBuf = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(service, &classBuf)
        let className = String(cString: classBuf)

        let cf = IORegistryEntryCreateCFProperty(
            service,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0)?.takeRetainedValue() as? [String: Any]

        // The integer percent key. Some service variants expose it without
        // the "%" suffix, so try both.
        let raw =
            (cf?["Device Utilization %"] as? NSNumber)?.doubleValue
            ?? (cf?["Device Utilization"]   as? NSNumber)?.doubleValue
            ?? (cf?["GPU Activity(%)"]      as? NSNumber)?.doubleValue

        return IOAcceleratorSelection.Reading(name: name, className: className, utilization: raw)
    }

    private func logServicesIfFirstRead(_ readings: [IOAcceleratorSelection.Reading], contributingCount: Int) {
        lock.lock()
        let shouldLog = !hasLogged
        hasLogged = true
        lock.unlock()
        guard shouldLog else { return }

        // Service count is coarse and useful in release logs.
        os_log("IOAccelerator: %d service(s) detected", log: ioaLog, type: .info, readings.count)
        // Per-service names / class strings are device-fingerprinting data;
        // emit at .debug and mark %{private} so they are redacted in release
        // logs unless private logging is explicitly enabled (Codex security
        // audit, 2026-05-04, finding #16).
        for r in readings {
            let utilString = r.utilization.map { String(format: "%.0f%%", $0) } ?? "n/a"
            os_log("  name=%{private}s class=%{private}s util=%{public}s",
                   log: ioaLog, type: .debug,
                   r.name, r.className, utilString)
        }
        if contributingCount > 1 {
            os_log("Multi-GPU detected: aggregating %d services by max utilization",
                   log: ioaLog, type: .info, contributingCount)
        }
    }
}
