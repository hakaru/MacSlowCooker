import Foundation

/// Runtime detection of the *host* CPU architecture, regardless of which
/// arch slice of the binary the OS chose to run.
///
/// `#if arch(arm64)` is compile-time and reflects which slice is currently
/// executing — but a Universal Binary's x86_64 slice will run under Rosetta
/// 2 on Apple Silicon, and we want sampler arguments that match the
/// underlying hardware (the kernel still exposes ANE / Apple GPU
/// regardless of the translation layer). `hw.optional.arm64` is set by the
/// kernel on Apple Silicon hosts and is visible from a translated process.
enum HostCPU {
    static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        // sysctlbyname returns 0 on success. On Intel Macs the key is
        // typically absent and returns -1; treat any failure as "not Apple
        // Silicon" so the sampler args match Intel hardware behavior.
        return result == 0 && value == 1
    }()
}
