import XCTest
@testable import MacSlowCooker

@MainActor
final class SettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "com.macslowcooker.tests.settings"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
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
        defaults.set("nonsense", forKey: Settings.Keys.flameAnimation)
        defaults.set("",         forKey: Settings.Keys.boilingTrigger)

        let s = Settings(defaults: defaults)
        XCTAssertEqual(s.flameAnimation, .both)
        XCTAssertEqual(s.boilingTrigger, .combined)
    }

    func testEachSetterPersists() {
        let s = Settings(defaults: defaults)
        s.potStyle = .dutchOven
        s.flameAnimation = .interpolation
        s.boilingTrigger = .thermalPressure

        XCTAssertEqual(defaults.string(forKey: Settings.Keys.potStyle),       "dutchOven")
        XCTAssertEqual(defaults.string(forKey: Settings.Keys.flameAnimation), "interpolation")
        XCTAssertEqual(defaults.string(forKey: Settings.Keys.boilingTrigger), "thermalPressure")
    }

    func testResetToDefaults() {
        let s = Settings(defaults: defaults)
        s.flameAnimation = .none
        s.boilingTrigger = .temperature
        s.floatAboveOtherWindows = false

        s.resetToDefaults()

        XCTAssertEqual(s.potStyle, .dutchOven)
        XCTAssertEqual(s.flameAnimation, .both)
        XCTAssertEqual(s.boilingTrigger, .combined)
        XCTAssertTrue(s.floatAboveOtherWindows)

        // didSet wrote each default through to UserDefaults so a fresh
        // instance built from the same store reads the reset values.
        let s2 = Settings(defaults: defaults)
        XCTAssertEqual(s2.flameAnimation, .both)
        XCTAssertEqual(s2.boilingTrigger, .combined)
        XCTAssertTrue(s2.floatAboveOtherWindows)
    }

    func testChangesStreamYieldsOnEachMutation() async {
        let s = Settings(defaults: defaults)

        // Settings is @MainActor — Task body must be too.
        let task = Task<Int, Never> { @MainActor [s] in
            var count = 0
            for await _ in s.changes {
                count += 1
                if count == 2 { break }
            }
            return count
        }

        // Give the tracker time to arm
        try? await Task.sleep(nanoseconds: 50_000_000)

        s.flameAnimation = .wiggle
        try? await Task.sleep(nanoseconds: 20_000_000)
        s.boilingTrigger = .temperature

        let count = await task.value
        XCTAssertEqual(count, 2)
    }
}
