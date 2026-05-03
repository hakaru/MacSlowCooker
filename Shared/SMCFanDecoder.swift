import Foundation

/// Pure decoder for SMC fan-speed key payloads. Extracted from `SMCReader`
/// so the byte-level math can be unit-tested without going through
/// `IOServiceOpen`. Two formats appear on Apple Silicon Macs:
///
///   - `fpe2` — 16-bit big-endian fixed point, 14 integer + 2 fractional
///     bits. Raw value `(b[0] << 8) | b[1]`, divided by 4. Legacy format
///     used on Intel Macs and earlier Apple Silicon SMCs for fan RPM.
///   - `flt ` — 32-bit IEEE 754 float in **little-endian** byte order
///     (Apple Silicon SMC quirk; despite SMC's big-endian heritage the float
///     types are LE on M-series hardware).
///
/// Returns `nil` when the dataType is unknown or the byte buffer is too
/// short to decode.
enum SMCFanDecoder {

    static func decode(bytes: [UInt8], dataType: String) -> Double? {
        switch dataType {
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 4.0
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw =  UInt32(bytes[0])
                    | (UInt32(bytes[1]) <<  8)
                    | (UInt32(bytes[2]) << 16)
                    | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: raw))
        default:
            return nil
        }
    }
}
