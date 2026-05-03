import Foundation

/// Pure splitter for the NUL-separated plist stream `powermetrics --format
/// plist` emits. `powermetrics` writes one binary plist per sample and ends
/// each with a NUL byte (0x00). Network/pipe reads can deliver partial or
/// multiple samples per chunk, so we buffer bytes and slice on each NUL we
/// encounter.
///
/// Extracted from `PowerMetricsRunner` so the buffering / split logic can be
/// unit-tested independently of `Process` / `Pipe`. Thread-affinity is
/// caller-managed: the splitter mutates state and is intended to be used
/// from one queue at a time.
final class PlistStreamSplitter {

    private var buffer = Data()

    /// Append a chunk of bytes to the buffer and return any complete plist
    /// payloads that the new data made available. Each returned `Data` is the
    /// bytes between two consecutive NUL separators, with the trailing NUL
    /// stripped. Empty payloads (consecutive NULs) are discarded.
    func append(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        return drainCompletePlists()
    }

    /// Number of bytes currently buffered without a terminating NUL.
    /// Useful for tests; production code does not need to inspect this.
    var bufferedByteCount: Int { buffer.count }

    /// Drop everything in the buffer. Used by `stop()` to reset state on
    /// the next run.
    func reset() {
        buffer.removeAll()
    }

    private func drainCompletePlists() -> [Data] {
        var out: [Data] = []
        let nul = Data([0])
        while let range = buffer.range(of: nul) {
            let chunk = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            if !chunk.isEmpty {
                out.append(chunk)
            }
        }
        return out
    }
}
