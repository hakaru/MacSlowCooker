import XCTest
@testable import MacSlowCooker

@MainActor
final class SettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "com.macslowcooker.tests.settings"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func testDefaultValues() {
        let s = Settings(defaults: defaults)
        XCTAssertEqual(s.potStyle, .dutchOven)
        XCTAssertEqual(s.flameAnimation, .both)
        XCTAssertEqual(s.boilingTrigger, .combined)
    }

    func testPersistsChanges() {
        let s1 = Settings(defaults: defaults)
        s1.flameAnimation = .wiggle
        s1.boilingTrigger = .temperature

        let s2 = Settings(defaults: defaults)
        XCTAssertEqual(s2.flameAnimation, .wiggle)
        XCTAssertEqual(s2.boilingTrigger, .temperature)
    }

    func testFallsBackOnInvalidRawValue() {
        defaults.set("nonsense", forKey: "flameAnimation")
        defaults.set("",         forKey: "boilingTrigger")

        let s = Settings(defaults: defaults)
        XCTAssertEqual(s.flameAnimation, .both)
        XCTAssertEqual(s.boilingTrigger, .combined)
    }

    func testEachSetterPersists() {
        let s = Settings(defaults: defaults)
        s.potStyle = .dutchOven
        s.flameAnimation = .interpolation
        s.boilingTrigger = .thermalPressure

        XCTAssertEqual(defaults.string(forKey: "potStyle"),       "dutchOven")
        XCTAssertEqual(defaults.string(forKey: "flameAnimation"), "interpolation")
        XCTAssertEqual(defaults.string(forKey: "boilingTrigger"), "thermalPressure")
    }
}
