import XCTest
@testable import MacSlowCooker

@MainActor
final class SettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "com.macslowcooker.tests.settings"
    private let testKeychain = KeychainStore(service: "com.macslowcooker.tests.license")

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
        testKeychain.delete(forKey: Settings.Keys.licenseKey)
        testKeychain.delete(forKey: Settings.Keys.licenseVerifiedAt)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        testKeychain.delete(forKey: Settings.Keys.licenseKey)
        testKeychain.delete(forKey: Settings.Keys.licenseVerifiedAt)
        try await super.tearDown()
    }

    func testDefaultValues() {
        let s = Settings(defaults: defaults, keychain: testKeychain)
        XCTAssertEqual(s.potStyle, .dutchOven)
        XCTAssertEqual(s.flameAnimation, .both)
        XCTAssertEqual(s.boilingTrigger, .combined)
    }

    func testPersistsChanges() {
        let s1 = Settings(defaults: defaults, keychain: testKeychain)
        s1.flameAnimation = .wiggle
        s1.boilingTrigger = .temperature

        let s2 = Settings(defaults: defaults, keychain: testKeychain)
        XCTAssertEqual(s2.flameAnimation, .wiggle)
        XCTAssertEqual(s2.boilingTrigger, .temperature)
    }

    func testFallsBackOnInvalidRawValue() {
        defaults.set("nonsense", forKey: Settings.Keys.flameAnimation)
        defaults.set("",         forKey: Settings.Keys.boilingTrigger)

        let s = Settings(defaults: defaults, keychain: testKeychain)
        XCTAssertEqual(s.flameAnimation, .both)
        XCTAssertEqual(s.boilingTrigger, .combined)
    }

    func testEachSetterPersists() {
        let s = Settings(defaults: defaults, keychain: testKeychain)
        s.potStyle = .dutchOven
        s.flameAnimation = .interpolation
        s.boilingTrigger = .thermalPressure

        XCTAssertEqual(defaults.string(forKey: Settings.Keys.potStyle),       "dutchOven")
        XCTAssertEqual(defaults.string(forKey: Settings.Keys.flameAnimation), "interpolation")
        XCTAssertEqual(defaults.string(forKey: Settings.Keys.boilingTrigger), "thermalPressure")
    }

    func testResetToDefaults() {
        let s = Settings(defaults: defaults, keychain: testKeychain)
        s.flameAnimation = .none
        s.boilingTrigger = .temperature
        s.floatAboveOtherWindows = false

        s.resetToDefaults()

        XCTAssertEqual(s.potStyle, .dutchOven)
        XCTAssertEqual(s.flameAnimation, .both)
        XCTAssertEqual(s.boilingTrigger, .combined)
        XCTAssertTrue(s.floatAboveOtherWindows)

        let s2 = Settings(defaults: defaults, keychain: testKeychain)
        XCTAssertEqual(s2.flameAnimation, .both)
        XCTAssertEqual(s2.boilingTrigger, .combined)
        XCTAssertTrue(s2.floatAboveOtherWindows)
    }

    func testChangesStreamYieldsOnEachMutation() async {
        let s = Settings(defaults: defaults, keychain: testKeychain)

        let task = Task<Int, Never> { @MainActor [s] in
            var count = 0
            for await _ in s.changes {
                count += 1
                if count == 2 { break }
            }
            return count
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        s.flameAnimation = .wiggle
        try? await Task.sleep(nanoseconds: 20_000_000)
        s.boilingTrigger = .temperature

        let count = await task.value
        XCTAssertEqual(count, 2)
    }

    func testLicenseKeyPersistsToKeychain() {
        let s = Settings(defaults: defaults, keychain: testKeychain)
        s.licenseKey = "ABCD-1234-EFGH-5678"

        let s2 = Settings(defaults: defaults, keychain: testKeychain)
        XCTAssertEqual(s2.licenseKey, "ABCD-1234-EFGH-5678")
    }

    func testLicenseKeyNilClearsKeychain() {
        let s = Settings(defaults: defaults, keychain: testKeychain)
        s.licenseKey = "ABCD-1234-EFGH-5678"
        s.licenseKey = nil

        let s2 = Settings(defaults: defaults, keychain: testKeychain)
        XCTAssertNil(s2.licenseKey)
    }

    func testLicenseVerifiedAtPersistsToKeychain() {
        let s = Settings(defaults: defaults, keychain: testKeychain)
        let now = Date()
        s.licenseVerifiedAt = now

        let s2 = Settings(defaults: defaults, keychain: testKeychain)
        XCTAssertNotNil(s2.licenseVerifiedAt)
        XCTAssertEqual(
            s2.licenseVerifiedAt!.timeIntervalSince1970,
            now.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testLicenseVerifiedAtNilClearsKeychain() {
        let s = Settings(defaults: defaults, keychain: testKeychain)
        s.licenseVerifiedAt = Date()
        s.licenseVerifiedAt = nil

        let s2 = Settings(defaults: defaults, keychain: testKeychain)
        XCTAssertNil(s2.licenseVerifiedAt)
    }

    func testResetToDefaultsDoesNotClearLicense() {
        let s = Settings(defaults: defaults, keychain: testKeychain)
        s.licenseKey = "ABCD-1234-EFGH-5678"
        s.licenseVerifiedAt = Date()
        s.resetToDefaults()

        XCTAssertEqual(s.licenseKey, "ABCD-1234-EFGH-5678")
        XCTAssertNotNil(s.licenseVerifiedAt)
    }
}
