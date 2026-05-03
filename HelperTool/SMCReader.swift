import Foundation
import IOKit
import os.log

private let smcLog = OSLog(subsystem: "com.macslowcooker", category: "smc")

/// Minimal SMC reader for fan RPMs. Apple Silicon (M1+) exposes fan info via the
/// AppleSMC service. We open a connection once and read F0Ac…FnAc keys (fpe2 format)
/// to derive current RPM. Number of fans comes from the FNum key.
///
/// The SMCKeyData struct layout matches what AppleSMC's user-client expects.
final class SMCReader {

    // MARK: - SMC param struct (matches AppleSMC.kext expected layout)

    private struct SMCKeyDataVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCKeyDataLimits {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyDataKeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    // 32-byte payload buffer. Tuple matches the fixed-size C array Apple's SMC kext expects.
    private typealias SMCBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers = SMCKeyDataVersion()
        var pLimitData = SMCKeyDataLimits()
        var keyInfo = SMCKeyDataKeyInfo()
        // AppleSMC's C struct has 2-byte padding here (after keyInfo's 1-byte
        // dataAttributes) to align `result` onto an even offset. Without this,
        // Swift's natural layout still happens to align — but the struct's total
        // stride won't match what the kext expects.
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCKeyInfo: UInt8 = 9

    // MARK: - State

    private var connection: io_connect_t = 0
    private var fanCount: Int = 0

    // MARK: - Init / lifecycle

    /// Total stride AppleSMC's user-client expects for the parameter struct.
    /// Hard-coded so future Swift compiler optimizations or struct edits that
    /// shift offsets are caught immediately rather than producing garbled
    /// kernel reads.
    static let expectedKeyDataStride: Int = 80

    init?() {
        let actualStride = MemoryLayout<SMCKeyData>.stride
        guard actualStride == Self.expectedKeyDataStride else {
            os_log("SMCKeyData stride drift: %d != %d (expected). Refusing to open SMC.",
                   log: smcLog, type: .error,
                   actualStride, Self.expectedKeyDataStride)
            return nil
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            os_log("AppleSMC service not found", log: smcLog, type: .error)
            return nil
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            os_log("IOServiceOpen failed: %x", log: smcLog, type: .error, result)
            return nil
        }

        if let count = readUInt8(key: "FNum") {
            fanCount = Int(count)
            os_log("SMC: detected %d fan(s)", log: smcLog, type: .info, fanCount)
        } else {
            os_log("SMC: FNum read failed (no fans or read error)", log: smcLog, type: .error)
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    // MARK: - Public API

    /// Returns the current RPM for each fan. Empty array on machines without fans
    /// or if the read fails.
    func readFanRPMs() -> [Double] {
        guard fanCount > 0 else { return [] }
        var rpms: [Double] = []
        for i in 0..<fanCount {
            if let rpm = readFloat(key: "F\(i)Ac") {
                rpms.append(rpm)
            }
        }
        return rpms
    }

    // MARK: - Key reads

    private func readUInt8(key: String) -> UInt8? {
        guard let (bytes, _) = readKey(key) else { return nil }
        return bytes.first
    }

    /// Reads an SMC key whose value represents a number. Decoding is
    /// delegated to `SMCFanDecoder` so it can be unit-tested without going
    /// through `IOServiceOpen`. Logs on unknown dataType for diagnosability.
    private func readFloat(key: String) -> Double? {
        guard let (bytes, dataType) = readKey(key) else { return nil }
        if let value = SMCFanDecoder.decode(bytes: bytes, dataType: dataType) {
            return value
        }
        os_log("SMC unknown dataType for %{public}s: %{public}s",
               log: smcLog, type: .error, key, dataType)
        return nil
    }

    /// Returns the raw bytes plus the SMC dataType code (e.g., "fpe2", "flt ").
    private func readKey(_ key: String) -> (bytes: [UInt8], dataType: String)? {
        let keyCode = fourCharCode(key)
        guard keyCode != 0 else { return nil }

        // First call: get key info (data size + type) so we can choose the right decoder.
        var inStruct = SMCKeyData()
        inStruct.key = keyCode
        inStruct.data8 = Self.kSMCKeyInfo
        var outStruct = SMCKeyData()
        guard call(input: &inStruct, output: &outStruct) else { return nil }
        let dataSize = outStruct.keyInfo.dataSize
        let dataType = decodeFourCC(outStruct.keyInfo.dataType)
        guard dataSize > 0, dataSize <= 32 else { return nil }

        // Second call: actually read the bytes.
        inStruct = SMCKeyData()
        inStruct.key = keyCode
        inStruct.keyInfo.dataSize = dataSize
        inStruct.data8 = Self.kSMCReadKey
        outStruct = SMCKeyData()
        guard call(input: &inStruct, output: &outStruct) else { return nil }

        let n = Int(dataSize)
        var result = [UInt8](repeating: 0, count: n)
        withUnsafeBytes(of: &outStruct.bytes) { raw in
            for i in 0..<n { result[i] = raw[i] }
        }
        return (result, dataType)
    }

    private func decodeFourCC(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >>  8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> Bool {
        let inSize = MemoryLayout<SMCKeyData>.stride
        var outSize = MemoryLayout<SMCKeyData>.stride
        let result = withUnsafePointer(to: &input) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                IOConnectCallStructMethod(
                    connection,
                    Self.kSMCHandleYPCEvent,
                    inPtr, inSize,
                    outPtr, &outSize)
            }
        }
        if result != kIOReturnSuccess {
            os_log("SMC call failed: ioret=%x", log: smcLog, type: .debug, result)
            return false
        }
        if output.result != 0 {
            return false
        }
        return true
    }

    private func fourCharCode(_ s: String) -> UInt32 {
        let bytes = Array(s.utf8)
        guard bytes.count == 4 else { return 0 }
        return (UInt32(bytes[0]) << 24)
             | (UInt32(bytes[1]) << 16)
             | (UInt32(bytes[2]) <<  8)
             |  UInt32(bytes[3])
    }
}
