import XCTest
@testable import MacSlowCooker

final class KeychainStoreTests: XCTestCase {

    private let store = KeychainStore(service: "com.macslowcooker.tests.keychain")

    override func setUp() {
        store.delete(forKey: "testKey")
    }

    override func tearDown() {
        store.delete(forKey: "testKey")
    }

    func testWriteAndRead() {
        store.write("hello", forKey: "testKey")
        XCTAssertEqual(store.read(forKey: "testKey"), "hello")
    }

    func testOverwrite() {
        store.write("v1", forKey: "testKey")
        store.write("v2", forKey: "testKey")
        XCTAssertEqual(store.read(forKey: "testKey"), "v2")
    }

    func testDelete() {
        store.write("hello", forKey: "testKey")
        store.delete(forKey: "testKey")
        XCTAssertNil(store.read(forKey: "testKey"))
    }

    func testReadMissingReturnsNil() {
        XCTAssertNil(store.read(forKey: "testKey"))
    }
}
