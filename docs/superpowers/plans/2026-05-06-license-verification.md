# License Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MacSlowCooker の Preferences に License セクションを追加し、Gumroad ライセンスキーを Keychain に保存・検証する（オプション機能 — ライセンスなしでも全機能利用可）。

**Architecture:** `KeychainStore`（新規 pure helper）が SecItem API をラップ; `LicenseValidator`（新規 pure struct）が注入可能な fetch クロージャで `api.gumroad.com/v2/licenses/verify` を呼ぶ; `Settings` に Keychain バックの `licenseKey` + `licenseVerifiedAt` プロパティを追加; `PreferencesView` に License セクション（テキストフィールド + Verify ボタン + 状態表示）を追加。

**Tech Stack:** Swift, Security framework (Keychain), URLSession, SwiftUI, XCTest

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `MacSlowCooker/KeychainStore.swift` | SecItem read/write/delete の薄いラッパー |
| Create | `MacSlowCookerTests/KeychainStoreTests.swift` | KeychainStore ユニットテスト |
| Create | `MacSlowCooker/LicenseValidator.swift` | 非同期 Gumroad ライセンス検証、fetch 注入可能 |
| Create | `MacSlowCookerTests/LicenseValidatorTests.swift` | LicenseValidator ユニットテスト |
| Modify | `MacSlowCooker/Settings.swift` | licenseKey + licenseVerifiedAt（Keychain バック）追加 |
| Modify | `MacSlowCookerTests/SettingsTests.swift` | ライセンスプロパティ永続化テスト追加 |
| Modify | `MacSlowCooker/PreferencesWindowController.swift` | PreferencesView に License セクション追加 |

---

### Task 1: KeychainStore

**Files:**
- Create: `MacSlowCooker/KeychainStore.swift`
- Create: `MacSlowCookerTests/KeychainStoreTests.swift`

- [ ] **Step 1: 失敗するテストを書く**

`MacSlowCookerTests/KeychainStoreTests.swift` を新規作成:

```swift
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
```

- [ ] **Step 2: xcodegen 実行後、テストが失敗することを確認**

```bash
cd /path/to/MacSlowCooker
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/KeychainStoreTests 2>&1 | grep -E "error:|KeychainStore"
```

Expected: `error: cannot find type 'KeychainStore'`

- [ ] **Step 3: KeychainStore を実装**

`MacSlowCooker/KeychainStore.swift` を新規作成:

```swift
import Foundation
import Security

struct KeychainStore {
    let service: String

    func write(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        let attrs: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func read(forKey key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(forKey key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 4: テスト実行・全通過を確認**

```bash
cd /path/to/MacSlowCooker
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/KeychainStoreTests 2>&1 | grep -E "Test Suite.*passed|error:|FAILED"
```

Expected: `Test Suite 'KeychainStoreTests' passed`

- [ ] **Step 5: コミット**

```bash
git add MacSlowCooker/KeychainStore.swift MacSlowCookerTests/KeychainStoreTests.swift
git commit -m "feat: add KeychainStore wrapper for SecItem read/write/delete"
```

---

### Task 2: LicenseValidator

**Files:**
- Create: `MacSlowCooker/LicenseValidator.swift`
- Create: `MacSlowCookerTests/LicenseValidatorTests.swift`

- [ ] **Step 1: 失敗するテストを書く**

`MacSlowCookerTests/LicenseValidatorTests.swift` を新規作成:

```swift
import XCTest
@testable import MacSlowCooker

final class LicenseValidatorTests: XCTestCase {

    private func makeResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.gumroad.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func testVerifyReturnsVerifiedOnSuccess() async {
        let body = #"{"success":true,"purchase":{"license_key":"ABCD-1234-EFGH-5678"}}"#
        let validator = LicenseValidator(productPermalink: "fzifrw") { _ in
            (Data(body.utf8), self.makeResponse(statusCode: 200))
        }
        let result = await validator.verify(key: "ABCD-1234-EFGH-5678")
        XCTAssertEqual(result, .verified)
    }

    func testVerifyReturnsInvalidOnFailure() async {
        let body = #"{"success":false,"message":"That license does not exist for the provided product."}"#
        let validator = LicenseValidator(productPermalink: "fzifrw") { _ in
            (Data(body.utf8), self.makeResponse(statusCode: 404))
        }
        let result = await validator.verify(key: "INVALID-KEY")
        XCTAssertEqual(result, .invalid("That license does not exist for the provided product."))
    }

    func testVerifyReturnsNetworkErrorOnThrow() async {
        let validator = LicenseValidator(productPermalink: "fzifrw") { _ in
            throw URLError(.notConnectedToInternet)
        }
        let result = await validator.verify(key: "ANY-KEY")
        if case .networkError = result { } else {
            XCTFail("Expected .networkError, got \(result)")
        }
    }

    func testVerifySendsCorrectFormBody() async {
        var capturedRequest: URLRequest?
        let body = #"{"success":true}"#
        let validator = LicenseValidator(productPermalink: "fzifrw") { req in
            capturedRequest = req
            return (Data(body.utf8), self.makeResponse(statusCode: 200))
        }
        _ = await validator.verify(key: "MY-KEY-1234")
        let bodyString = String(data: capturedRequest!.httpBody!, encoding: .utf8)!
        XCTAssertTrue(bodyString.contains("product_permalink=fzifrw"), "body: \(bodyString)")
        XCTAssertTrue(bodyString.contains("license_key=MY-KEY-1234"), "body: \(bodyString)")
        XCTAssertTrue(bodyString.contains("increment_uses_count=false"), "body: \(bodyString)")
    }

    func testVerifyUsesInvalidMessageFallback() async {
        let body = #"{"success":false}"#
        let validator = LicenseValidator(productPermalink: "fzifrw") { _ in
            (Data(body.utf8), self.makeResponse(statusCode: 404))
        }
        let result = await validator.verify(key: "BAD-KEY")
        XCTAssertEqual(result, .invalid("Invalid license key"))
    }
}
```

- [ ] **Step 2: xcodegen 実行後、テストが失敗することを確認**

```bash
cd /path/to/MacSlowCooker
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/LicenseValidatorTests 2>&1 | grep -E "error:|LicenseValidator"
```

Expected: `error: cannot find type 'LicenseValidator'`

- [ ] **Step 3: LicenseValidator を実装**

`MacSlowCooker/LicenseValidator.swift` を新規作成:

```swift
import Foundation

enum LicenseVerificationResult: Equatable {
    case verified
    case invalid(String)
    case networkError(String)
}

struct LicenseValidator {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    let productPermalink: String
    var fetch: Fetch

    init(productPermalink: String, fetch: Fetch? = nil) {
        self.productPermalink = productPermalink
        self.fetch = fetch ?? { req in try await URLSession.shared.data(for: req) }
    }

    func verify(key: String) async -> LicenseVerificationResult {
        var request = URLRequest(
            url: URL(string: "https://api.gumroad.com/v2/licenses/verify")!
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        let body = [
            "product_permalink=\(productPermalink.formEncoded)",
            "license_key=\(key.formEncoded)",
            "increment_uses_count=false"
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        do {
            let (data, response) = try await fetch(request)
            guard response is HTTPURLResponse else {
                return .networkError("No HTTP response")
            }
            struct GumroadResponse: Decodable {
                let success: Bool
                let message: String?
            }
            let decoded = try JSONDecoder().decode(GumroadResponse.self, from: data)
            return decoded.success
                ? .verified
                : .invalid(decoded.message ?? "Invalid license key")
        } catch {
            return .networkError(error.localizedDescription)
        }
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
```

- [ ] **Step 4: テスト実行・全通過を確認**

```bash
cd /path/to/MacSlowCooker
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/LicenseValidatorTests 2>&1 | grep -E "Test Suite.*passed|error:|FAILED"
```

Expected: `Test Suite 'LicenseValidatorTests' passed`

- [ ] **Step 5: コミット**

```bash
git add MacSlowCooker/LicenseValidator.swift MacSlowCookerTests/LicenseValidatorTests.swift
git commit -m "feat: add LicenseValidator async Gumroad license verifier"
```

---

### Task 3: Settings — ライセンスプロパティ追加

**Files:**
- Modify: `MacSlowCooker/Settings.swift`
- Modify: `MacSlowCookerTests/SettingsTests.swift`

- [ ] **Step 1: 失敗するテストを書く**

`MacSlowCookerTests/SettingsTests.swift` の `SettingsTests` クラスを以下の通り更新。`setUp`/`tearDown` に keychain クリーンアップを追加し、新規テストメソッドを追記する:

```swift
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

    // --- 既存テスト（変更なし） ---

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

    // --- 新規テスト ---

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
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
cd /path/to/MacSlowCooker
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/SettingsTests 2>&1 | grep -E "error:|licenseKey|keychain:"
```

Expected: `error: extra argument 'keychain:' in call` と `error: value of type 'Settings' has no member 'licenseKey'`

- [ ] **Step 3: Settings.swift を更新**

`MacSlowCooker/Settings.swift` を以下の完全版に置き換える:

```swift
import Foundation
import Observation

@Observable
@MainActor
final class Settings {

    enum Keys {
        static let potStyle       = "potStyle"
        static let flameAnimation = "flameAnimation"
        static let boilingTrigger = "boilingTrigger"
        static let floatAboveOtherWindows = "floatAboveOtherWindows"
        static let prometheusEnabled      = "prometheusEnabled"
        static let prometheusPort         = "prometheusPort"
        static let prometheusBindAll      = "prometheusBindAll"
        static let pngExportEnabled = "pngExportEnabled"
        static let pngExportPath    = "pngExportPath"
        static let licenseKey        = "licenseKey"
        static let licenseVerifiedAt = "licenseVerifiedAt"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    private let keychain: KeychainStore

    var potStyle: PotStyle = .dutchOven {
        didSet { defaults.set(potStyle.rawValue, forKey: Keys.potStyle) }
    }

    var flameAnimation: FlameAnimation = .both {
        didSet { defaults.set(flameAnimation.rawValue, forKey: Keys.flameAnimation) }
    }

    var boilingTrigger: BoilingTrigger = .combined {
        didSet { defaults.set(boilingTrigger.rawValue, forKey: Keys.boilingTrigger) }
    }

    var floatAboveOtherWindows: Bool = true {
        didSet { defaults.set(floatAboveOtherWindows, forKey: Keys.floatAboveOtherWindows) }
    }

    var prometheusEnabled: Bool = false {
        didSet { defaults.set(prometheusEnabled, forKey: Keys.prometheusEnabled) }
    }

    var prometheusPort: Int = 9091 {
        didSet { defaults.set(prometheusPort, forKey: Keys.prometheusPort) }
    }

    var prometheusBindAll: Bool = false {
        didSet { defaults.set(prometheusBindAll, forKey: Keys.prometheusBindAll) }
    }

    var pngExportEnabled: Bool = false {
        didSet { defaults.set(pngExportEnabled, forKey: Keys.pngExportEnabled) }
    }

    var pngExportPath: String = Settings.defaultPNGExportPath {
        didSet { defaults.set(pngExportPath, forKey: Keys.pngExportPath) }
    }

    var licenseKey: String? = nil {
        didSet {
            if let v = licenseKey { keychain.write(v, forKey: Keys.licenseKey) }
            else { keychain.delete(forKey: Keys.licenseKey) }
        }
    }

    var licenseVerifiedAt: Date? = nil {
        didSet {
            if let d = licenseVerifiedAt {
                keychain.write(
                    ISO8601DateFormatter().string(from: d),
                    forKey: Keys.licenseVerifiedAt
                )
            } else {
                keychain.delete(forKey: Keys.licenseVerifiedAt)
            }
        }
    }

    /// ライセンスキーと検証日時は意図的にリセットしない（アカウント情報は設定とは別）
    func resetToDefaults() {
        potStyle = .dutchOven
        flameAnimation = .both
        boilingTrigger = .combined
        floatAboveOtherWindows = true
        prometheusEnabled = false
        prometheusPort    = 9091
        prometheusBindAll = false
        pngExportEnabled = false
        pngExportPath    = Settings.defaultPNGExportPath
    }

    static var defaultPNGExportPath: String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacSlowCooker", isDirectory: true)
            .appendingPathComponent("web", isDirectory: true)
        return dir.path
    }

    static let shared = Settings()

    init(defaults: UserDefaults = .standard,
         keychain: KeychainStore = KeychainStore(service: "com.macslowcooker.app")) {
        self.defaults = defaults
        self.keychain = keychain
        self.potStyle       = PotStyle(rawValue: defaults.string(forKey: Keys.potStyle) ?? "")        ?? .dutchOven
        self.flameAnimation = FlameAnimation(rawValue: defaults.string(forKey: Keys.flameAnimation) ?? "") ?? .both
        self.boilingTrigger = BoilingTrigger(rawValue: defaults.string(forKey: Keys.boilingTrigger) ?? "") ?? .combined
        self.floatAboveOtherWindows = (defaults.object(forKey: Keys.floatAboveOtherWindows) as? Bool) ?? true
        self.prometheusEnabled = (defaults.object(forKey: Keys.prometheusEnabled) as? Bool) ?? false
        let storedPort = defaults.integer(forKey: Keys.prometheusPort)
        self.prometheusPort    = (1024...65535).contains(storedPort) ? storedPort : 9091
        self.prometheusBindAll = (defaults.object(forKey: Keys.prometheusBindAll) as? Bool) ?? false
        self.pngExportEnabled = (defaults.object(forKey: Keys.pngExportEnabled) as? Bool) ?? false
        self.pngExportPath    = (defaults.string(forKey: Keys.pngExportPath)) ?? Settings.defaultPNGExportPath
        self.licenseKey = keychain.read(forKey: Keys.licenseKey)
        if let s = keychain.read(forKey: Keys.licenseVerifiedAt) {
            self.licenseVerifiedAt = ISO8601DateFormatter().date(from: s)
        }
    }
}

extension Settings {

    var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let tracker = SettingsChangeTracker(settings: self) {
                continuation.yield(())
            }
            Task { @MainActor in tracker.start() }
            continuation.onTermination = { _ in
                Task { @MainActor in tracker.cancel() }
            }
        }
    }
}

@MainActor
private final class SettingsChangeTracker {
    private weak var settings: Settings?
    private let onChange: () -> Void
    private var cancelled = false

    init(settings: Settings, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange
    }

    func start() {
        guard !cancelled, let settings else { return }
        withObservationTracking {
            _ = settings.potStyle
            _ = settings.flameAnimation
            _ = settings.boilingTrigger
            _ = settings.floatAboveOtherWindows
            _ = settings.prometheusEnabled
            _ = settings.prometheusPort
            _ = settings.prometheusBindAll
            _ = settings.pngExportEnabled
            _ = settings.pngExportPath
            _ = settings.licenseKey
            _ = settings.licenseVerifiedAt
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled else { return }
                self.onChange()
                self.start()
            }
        }
    }

    nonisolated func cancel() {
        Task { @MainActor in self.cancelled = true }
    }
}
```

- [ ] **Step 4: テスト実行・全通過を確認**

```bash
cd /path/to/MacSlowCooker
xcodegen generate
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/SettingsTests 2>&1 | grep -E "Test Suite.*passed|error:|FAILED"
```

Expected: `Test Suite 'SettingsTests' passed`

- [ ] **Step 5: コミット**

```bash
git add MacSlowCooker/Settings.swift MacSlowCookerTests/SettingsTests.swift
git commit -m "feat: add licenseKey and licenseVerifiedAt Keychain-backed properties to Settings"
```

---

### Task 4: Preferences — License セクション UI

**Files:**
- Modify: `MacSlowCooker/PreferencesWindowController.swift`

SwiftUI View のユニットテストは省略（手動確認で検証）。

- [ ] **Step 1: PreferencesWindowController.swift を更新**

`MacSlowCooker/PreferencesWindowController.swift` を以下の完全版に置き換える。主な変更点:
- `window.setContentSize` を 640 → 720 に変更
- `PreferencesView` に `@State` 3 個と `verifyLicense()` メソッドを追加
- PNG Export セクションの後に License セクションを追加
- `.onAppear` で `draftKey` を初期化

```swift
import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {

    private let settings: Settings

    init(settings: Settings = .shared) {
        self.settings = settings
        let view = PreferencesView(settings: settings)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 720))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PreferencesView: View {
    @Bindable var settings: Settings

    @State private var draftKey: String = ""
    @State private var isVerifying = false
    @State private var licenseError: String? = nil

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Pot Style", selection: $settings.potStyle) {
                    Text("Dutch Oven").tag(PotStyle.dutchOven)
                }

                Picker("Flame Animation", selection: $settings.flameAnimation) {
                    Text("Off").tag(FlameAnimation.none)
                    Text("Interpolation").tag(FlameAnimation.interpolation)
                    Text("Wiggle").tag(FlameAnimation.wiggle)
                    Text("Both").tag(FlameAnimation.both)
                }
            }

            Section("Boiling Effect") {
                Picker("Trigger", selection: $settings.boilingTrigger) {
                    Text("Temperature ≥ 85°C").tag(BoilingTrigger.temperature)
                    Text("Thermal Pressure ≥ Serious").tag(BoilingTrigger.thermalPressure)
                    Text("Combined (Recommended)").tag(BoilingTrigger.combined)
                }
            }

            Section("Window") {
                Toggle("Float above other windows", isOn: $settings.floatAboveOtherWindows)
            }

            Section("Prometheus Exporter") {
                Toggle("Enable", isOn: $settings.prometheusEnabled)
                Stepper(value: $settings.prometheusPort, in: 1024...65535) {
                    HStack {
                        Text("Port")
                        Spacer()
                        Text("\(settings.prometheusPort)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.prometheusEnabled)
                Toggle("Bind to all interfaces (allows remote scraping)", isOn: $settings.prometheusBindAll)
                    .disabled(!settings.prometheusEnabled)
                if settings.prometheusEnabled {
                    if settings.prometheusBindAll {
                        Text("http://<this-Mac-IP>:\(settings.prometheusPort)/metrics")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Listens on all interfaces. macOS will prompt to allow incoming connections on first remote access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("http://127.0.0.1:\(settings.prometheusPort)/metrics")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("PNG Export") {
                Toggle("Enable", isOn: $settings.pngExportEnabled)
                HStack {
                    Text("Folder")
                    Spacer()
                    Text(abbreviatedPath(settings.pngExportPath))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                HStack {
                    Spacer()
                    Button("Choose Folder…") { chooseFolder() }
                    Button("Reveal in Finder") { revealInFinder() }
                        .disabled(!FileManager.default.fileExists(atPath: settings.pngExportPath))
                }
                if settings.pngExportEnabled {
                    Text("Re-rendered every 5 minutes. Serve with e.g. `python3 -m http.server -d \"\(settings.pngExportPath)\"`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("License") {
                HStack {
                    TextField("License Key", text: $draftKey)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.plain)
                    if isVerifying {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Button("Verify") {
                            Task { await verifyLicense() }
                        }
                        .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let verifiedAt = settings.licenseVerifiedAt,
                   settings.licenseKey == draftKey.trimmingCharacters(in: .whitespaces) {
                    Label(
                        "Verified \(verifiedAt.formatted(date: .abbreviated, time: .omitted))",
                        systemImage: "checkmark.seal.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.caption)
                } else if let error = licenseError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section("Energy") {
                LowPowerStatusRow()
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to defaults") { settings.resetToDefaults() }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            draftKey = settings.licenseKey ?? ""
        }
    }

    private func verifyLicense() async {
        let key = draftKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        isVerifying = true
        licenseError = nil
        let validator = LicenseValidator(productPermalink: "fzifrw")
        let result = await validator.verify(key: key)
        isVerifying = false
        switch result {
        case .verified:
            settings.licenseKey = key
            settings.licenseVerifiedAt = Date()
        case .invalid(let message):
            settings.licenseVerifiedAt = nil
            licenseError = message
        case .networkError(let message):
            licenseError = "Network error: \(message)"
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settings.pngExportPath)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.pngExportPath = url.path
        }
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: settings.pngExportPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Live readout of `ProcessInfo.isLowPowerModeEnabled`. The animator drops to
/// 5 fps and disables wiggle while LPM is on; surfacing the override here
/// avoids the user wondering why their wiggle setting has no visible effect.
private struct LowPowerStatusRow: View {
    @State private var isOn: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        HStack {
            Image(systemName: isOn ? "leaf.fill" : "leaf")
                .foregroundStyle(isOn ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(isOn ? "Low Power Mode is on" : "Low Power Mode is off")
                    .font(.system(size: 13))
                if isOn {
                    Text("Animation reduced to 5 fps and flame wiggle disabled.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isOn = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}
```

- [ ] **Step 2: ビルド確認**

```bash
cd /path/to/MacSlowCooker
xcodegen generate
xcodebuild build -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: 全テストスイート実行**

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite.*passed|error:|FAILED"
```

Expected: 全テストスイート passed

- [ ] **Step 4: コミット**

```bash
git add MacSlowCooker/PreferencesWindowController.swift
git commit -m "feat: add License section to Preferences with Gumroad key verification"
```
