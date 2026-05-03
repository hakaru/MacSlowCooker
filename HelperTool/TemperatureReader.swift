import Foundation
import IOKit

// MARK: - IOHIDEventSystem private symbols
// (Used by powermetrics, Stats, Chromium's m1_sensors_mac.mm, etc.)

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?

@discardableResult
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

private let kIOHIDEventTypeTemperature: Int64 = 15
private let temperatureField: Int32 = Int32(kIOHIDEventTypeTemperature << 16)
private let kHIDPage_AppleVendor = 0xff00
private let kHIDUsage_AppleVendor_TemperatureSensor = 5

/// Reads SoC die temperature in °C via IOHIDEventSystem.
///
/// macOS 26 / Apple Silicon M3 Ultra exposes only `PMU tdie*` / `PMU tdev*`
/// sensors via IOHID — the older `"GPU MTR Temp Sensor"` pattern is not
/// present on this hardware. We average all die-class sensors as the closest
/// available approximation. Real GPU-die-specific readings would require
/// SMC keys (`Tg05`, `Tg0D`) which we may add later.
///
/// Discovery happens once at init; the client is retained for the reader's
/// lifetime so the cached service references stay valid.
final class TemperatureReader {

    private let client: AnyObject?
    private let gpuServices: [AnyObject]

    init() {
        guard let unmanaged = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            self.client = nil
            self.gpuServices = []
            return
        }
        let c = unmanaged.takeRetainedValue()
        self.client = c

        let matching: [String: Any] = [
            "PrimaryUsagePage": kHIDPage_AppleVendor,
            "PrimaryUsage": kHIDUsage_AppleVendor_TemperatureSensor,
        ]
        IOHIDEventSystemClientSetMatching(c, matching as CFDictionary)

        var found: [AnyObject] = []
        if let servicesUnmanaged = IOHIDEventSystemClientCopyServices(c) {
            let services = servicesUnmanaged.takeRetainedValue() as [AnyObject]
            for service in services {
                guard let nameRef = IOHIDServiceClientCopyProperty(service, "Product" as CFString) else { continue }
                guard let name = nameRef.takeRetainedValue() as? String else { continue }
                let lower = name.lowercased()
                if lower.contains("die") || lower.contains("gpu")
                    || lower.contains("proximity") || lower.contains("graphics") {
                    found.append(service)
                }
            }
        }
        self.gpuServices = found
    }

    /// Returns the average GPU die temperature in °C, or nil if no sensors found
    /// or none returned a plausible reading this cycle.
    func readGPUTemperature() -> Double? {
        guard !gpuServices.isEmpty else { return nil }

        var values: [Double] = []
        for service in gpuServices {
            guard let eventUnmanaged = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0) else { continue }
            let event = eventUnmanaged.takeRetainedValue()
            let temp = IOHIDEventGetFloatValue(event, temperatureField)
            if temp > 0, temp < 150 {
                values.append(temp)
            }
        }

        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
