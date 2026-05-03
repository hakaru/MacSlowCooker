import Foundation
import IOKit
import os.log

private let ioaLog = OSLog(subsystem: "com.macslowcooker", category: "ioaccel")

/// Reads GPU utilization from `IOAccelerator`'s `PerformanceStatistics` dictionary,
/// which is the same source Activity Monitor uses for its "GPU History" graph.
///
/// `Device Utilization %` is integer percent (0–100). We pick a single service
/// deterministically (sorted by IORegistry entry name, first one with a usable
/// percentage) so reads do not jitter across reboots when service iteration
/// order changes. On first read, all detected services are logged for diagnosis.
final class IOAcceleratorReader {

    private struct Reading {
        let name: String
        let className: String
        let utilization: Double?
    }

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

        var readings: [Reading] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            readings.append(makeReading(service: service))
        }

        let sorted = readings.sorted { $0.name < $1.name }
        logServicesIfFirstRead(sorted)

        guard let chosen = sorted.first(where: { $0.utilization != nil }),
              let util = chosen.utilization else { return nil }
        return min(1.0, max(0.0, util / 100.0))
    }

    private func makeReading(service: io_object_t) -> Reading {
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

        return Reading(name: name, className: className, utilization: raw)
    }

    private func logServicesIfFirstRead(_ readings: [Reading]) {
        lock.lock()
        let shouldLog = !hasLogged
        hasLogged = true
        lock.unlock()
        guard shouldLog else { return }

        os_log("IOAccelerator: %d service(s) detected", log: ioaLog, type: .info, readings.count)
        for r in readings {
            let utilString = r.utilization.map { String(format: "%.0f%%", $0) } ?? "n/a"
            os_log("  name=%{public}s class=%{public}s util=%{public}s",
                   log: ioaLog, type: .info,
                   r.name, r.className, utilString)
        }
        if readings.filter({ $0.utilization != nil }).count > 1 {
            os_log("Multiple services report utilization — picking first by sorted name (multi-GPU aggregation TODO #10)",
                   log: ioaLog, type: .info)
        }
    }
}
