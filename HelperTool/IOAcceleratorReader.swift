import Foundation
import IOKit
import os.log

private let ioaLog = OSLog(subsystem: "com.macslowcooker", category: "ioaccel")

/// Reads GPU utilization from `IOAccelerator`'s `PerformanceStatistics` dictionary,
/// which is the same source Activity Monitor uses for the "GPU の履歴" graph.
///
/// `Device Utilization %` is integer percent (0–100). We return the maximum across
/// all matching IOAccelerator services (Mac Studio M3 Ultra has one merged
/// scheduler, but iterating defensively keeps us safe on multi-GPU configs).
final class IOAcceleratorReader {

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

        var found = false
        var maxUtil: Double = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            guard let cf = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0)?.takeRetainedValue() as? [String: Any] else { continue }

            // The integer percent key. Some service variants expose it without
            // the "%" suffix, so try both.
            let raw =
                (cf["Device Utilization %"] as? NSNumber)?.doubleValue
                ?? (cf["Device Utilization"]   as? NSNumber)?.doubleValue
                ?? (cf["GPU Activity(%)"]      as? NSNumber)?.doubleValue
            if let percent = raw {
                found = true
                maxUtil = max(maxUtil, percent)
            }
        }

        guard found else { return nil }
        return min(1.0, max(0.0, maxUtil / 100.0))
    }
}
