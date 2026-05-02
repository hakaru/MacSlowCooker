import XCTest
@testable import MacSlowCooker

@MainActor
final class GPUDataStoreTests: XCTestCase {

    func testAddSampleAppendsToBuffer() {
        let store = GPUDataStore()
        let sample = GPUSample(timestamp: Date(), gpuUsage: 0.5, temperature: 45.0, power: 6.0, aneUsage: 0.1)
        store.addSample(sample)

        XCTAssertEqual(store.samples.count, 1)
        XCTAssertEqual(store.latestSample?.gpuUsage, 0.5)
    }

    func testBufferCapAt60Elements() throws {
        let store = GPUDataStore()
        for i in 0..<70 {
            let sample = GPUSample(timestamp: Date(), gpuUsage: Double(i) / 100.0, temperature: nil, power: nil, aneUsage: nil)
            store.addSample(sample)
        }

        XCTAssertEqual(store.samples.count, 60)
        let lastUsage = try XCTUnwrap(store.latestSample?.gpuUsage)
        XCTAssertEqual(lastUsage, 0.69, accuracy: 0.001)
    }

    func testInitialStateIsEmpty() {
        let store = GPUDataStore()
        XCTAssertTrue(store.samples.isEmpty)
        XCTAssertNil(store.latestSample)
        XCTAssertFalse(store.isConnected)
    }

    func testSetConnectedUpdatesState() {
        let store = GPUDataStore()
        store.setConnected(true)
        XCTAssertTrue(store.isConnected)
        store.setConnected(false)
        XCTAssertFalse(store.isConnected)
    }
}
