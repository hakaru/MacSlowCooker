import XCTest
@testable import MacSlowCooker

final class PlistStreamSplitterTests: XCTestCase {

    private let nul: UInt8 = 0

    func testEmptyChunkReturnsNothing() {
        let s = PlistStreamSplitter()
        XCTAssertEqual(s.append(Data()), [])
        XCTAssertEqual(s.bufferedByteCount, 0)
    }

    func testSingleCompletePlistInOneChunk() {
        let s = PlistStreamSplitter()
        let payload = Data("hello".utf8)
        let chunk = payload + Data([nul])
        let out = s.append(chunk)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], payload)
        XCTAssertEqual(s.bufferedByteCount, 0)
    }

    func testTwoCompletePlistsInOneChunk() {
        let s = PlistStreamSplitter()
        let chunk = Data("aa".utf8) + Data([nul]) + Data("bb".utf8) + Data([nul])
        let out = s.append(chunk)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], Data("aa".utf8))
        XCTAssertEqual(out[1], Data("bb".utf8))
        XCTAssertEqual(s.bufferedByteCount, 0)
    }

    /// powermetrics often delivers a payload across pipe reads — the splitter
    /// must hold the partial bytes until the terminating NUL arrives.
    func testPlistSplitAcrossTwoChunks() {
        let s = PlistStreamSplitter()
        let head = s.append(Data("hel".utf8))
        XCTAssertEqual(head, [])
        XCTAssertEqual(s.bufferedByteCount, 3)

        let tail = s.append(Data("lo".utf8) + Data([nul]))
        XCTAssertEqual(tail.count, 1)
        XCTAssertEqual(tail[0], Data("hello".utf8))
        XCTAssertEqual(s.bufferedByteCount, 0)
    }

    /// One chunk completes a payload AND starts a new partial one. The
    /// completed payload should be emitted; the partial bytes should be kept
    /// for the next call.
    func testCompletePlusPartialInOneChunk() {
        let s = PlistStreamSplitter()
        let chunk = Data("aa".utf8) + Data([nul]) + Data("bb".utf8)
        let out = s.append(chunk)
        XCTAssertEqual(out, [Data("aa".utf8)])
        XCTAssertEqual(s.bufferedByteCount, 2)

        let final = s.append(Data([nul]))
        XCTAssertEqual(final, [Data("bb".utf8)])
    }

    /// Consecutive NULs (empty payload) should be silently dropped — they
    /// would round-trip through PowerMetricsParser.parse as nil samples and
    /// add no value.
    func testConsecutiveNulsDropEmptyPayloads() {
        let s = PlistStreamSplitter()
        let chunk = Data([nul, nul, nul])
        let out = s.append(chunk)
        XCTAssertEqual(out, [])
        XCTAssertEqual(s.bufferedByteCount, 0)
    }

    func testResetClearsBuffer() {
        let s = PlistStreamSplitter()
        _ = s.append(Data("partial".utf8))
        XCTAssertGreaterThan(s.bufferedByteCount, 0)
        s.reset()
        XCTAssertEqual(s.bufferedByteCount, 0)
        // After reset, a new payload should parse cleanly without leftover
        // bytes from the abandoned partial.
        let out = s.append(Data("fresh".utf8) + Data([nul]))
        XCTAssertEqual(out, [Data("fresh".utf8)])
    }
}
