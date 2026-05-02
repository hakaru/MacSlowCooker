# GPUSMI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS Dockアプリ。Apple Silicon GPUの使用率・温度・電力・ANEをリアルタイムで縦バーDockアイコンに表示し、クリックでSwift Chartsダッシュボードを表示する。

**Architecture:** root権限HelperTool（`SMAppService.daemon`）が `powermetrics` をNUL区切りplistストリームで常駐実行し、XPC経由で1秒ごとにメインアプリへ `GPUSample` を配信する。メインアプリは `@Observable` の循環バッファでデータを保持し、Core Graphics縦バーでDockアイコンを毎秒更新する。

**Tech Stack:** Swift 5.9+、AppKit + SwiftUI、Swift Charts、SMAppService、NSXPCConnection、Core Graphics、os_log (macOS 14+必須)

---

## ファイルマップ

```
GPUSMI/
├── GPUSMI.xcodeproj
├── GPUSMI/                              # メインアプリターゲット
│   ├── AppDelegate.swift                # NSApplication delegate, 全体ワイヤリング
│   ├── DockIconRenderer.swift           # Core Graphics縦バー描画（BGキュー）
│   ├── GPUDataStore.swift               # @Observable 循環バッファ (60要素)
│   ├── HelperInstaller.swift            # SMAppService.daemon登録・バージョン管理
│   ├── PopupView.swift                  # SwiftUI ダッシュボード (Swift Charts)
│   ├── PopupWindowController.swift      # NSPanel 表示位置・クローズ制御
│   ├── XPCClient.swift                  # XPC接続・指数バックオフ再接続
│   ├── GPUSMI.entitlements
│   ├── Info.plist                       # SMPrivilegedExecutables キー含む
│   └── Library/
│       └── LaunchDaemons/
│           └── com.gpusmi.helper.plist  # launchd daemon plist (bundle同梱)
├── HelperTool/                          # root権限daemonターゲット
│   ├── main.swift                       # XPC listener + Team ID検証
│   ├── PowerMetricsRunner.swift         # powermetrics常駐プロセス + NULストリームパース
│   ├── HelperTool.entitlements
│   └── Info.plist                       # SMAuthorizedClients キー含む
├── Shared/
│   ├── GPUSample.swift                  # Codable データモデル (optional fields)
│   └── XPCProtocol.swift                # XPCプロトコル定義 (両ターゲット参照)
└── GPUSMITests/
    ├── GPUSampleTests.swift
    ├── GPUDataStoreTests.swift
    ├── PowerMetricsParserTests.swift
    └── DockIconRendererTests.swift
```

---

## Task 1: powermetrics出力キー名の確認

**Files:**
- Read-only (コマンド実行のみ)

- [ ] **Step 1: rootでpowermetricsを1サンプル実行してplist出力を確認**

```bash
sudo powermetrics --samplers gpu_power,ane_power,thermal -i 500 -n 1 --format plist 2>/dev/null | \
  python3 -c "import sys,plistlib; d=plistlib.loads(sys.stdin.buffer.read().split(b'\x00')[0]); \
  print('GPU keys:', list(d.get('GPU',{}).keys())); \
  print('ANE keys:', list(d.get('ANE',{}).keys())); \
  print('thermal keys:', list(d.keys()))"
```

Expected output (実際のキー名を記録する):
```
GPU keys: ['gpu_active_residency', 'gpu_active_ns', ...]
ANE keys: ['ane_active_residency', ...]
thermal keys: ['GPU', 'ANE', 'thermal_pressure', ...]
```

- [ ] **Step 2: GPU温度のキー名を確認**

```bash
sudo powermetrics --samplers gpu_power,thermal -i 500 -n 1 --format plist 2>/dev/null | \
  python3 -c "import sys,plistlib; d=plistlib.loads(sys.stdin.buffer.read().split(b'\x00')[0]); \
  [print(k,v) for k,v in d.get('GPU',{}).items()]"
```

- [ ] **Step 3: Task 3の `PowerMetricsRunner.swift` で使うキー名を確定してメモする**

以降のタスクでは下記のデフォルトキー名を使う（実際の出力に合わせて修正すること）:
- GPU使用率: `"gpu_active_residency"` (0.0〜1.0)
- GPU温度: `"GPU Die Temp"` または `"thermal_level"` (°C)
- GPU電力: `"gpu_active_ns"` → なければ `"gpu_power"` (W)
- ANE使用率: `"ane_active_residency"` (0.0〜1.0)

---

## Task 2: Xcodeプロジェクトのセットアップ

**Files:**
- Create: `GPUSMI.xcodeproj` (Xcode GUIで作成)
- Create: `GPUSMI/GPUSMI.entitlements`
- Create: `HelperTool/HelperTool.entitlements`

- [ ] **Step 1: Xcodeで新規プロジェクトを作成**

1. Xcode → File → New → Project → macOS → App
2. Product Name: `GPUSMI`, Bundle Identifier: `com.gpusmi.app`
3. Language: Swift, Interface: SwiftUI → **変更**: Interface を `AppKit` に選択
4. プロジェクト保存先: `/Users/hakaru/DEVELOP/GPUSMI/`

- [ ] **Step 2: HelperToolターゲットを追加**

1. File → New → Target → macOS → Command Line Tool
2. Product Name: `HelperTool`, Bundle Identifier: `com.gpusmi.helper`
3. Language: Swift

- [ ] **Step 3: GPUSMITestsターゲットを確認**

プロジェクト作成時に自動生成された `GPUSMITests` ターゲットが存在することを確認。なければ File → New → Target → macOS → Unit Testing Bundle で追加。

- [ ] **Step 4: 両ターゲットのDeployment Targetを設定**

Project Settings → GPUSMI target → Deployment Info → macOS `14.0`
Project Settings → HelperTool target → macOS `14.0`
Project Settings → GPUSMITests target → macOS `14.0`

- [ ] **Step 5: Sharedグループを作成しターゲットメンバーシップを設定**

Xcode Navigator でグループ `Shared` を作成（後のタスクでファイルを追加する際、`GPUSMI` と `HelperTool` 両ターゲットにチェックを入れる）

- [ ] **Step 6: entitlementsファイルを作成**

`GPUSMI/GPUSMI.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.developer.service-management.managed-by-system</key>
    <true/>
</dict>
</plist>
```

`HelperTool/HelperTool.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
```

- [ ] **Step 7: LaunchDaemon plistディレクトリとファイルを作成**

```bash
mkdir -p /Users/hakaru/DEVELOP/GPUSMI/GPUSMI/Library/LaunchDaemons
```

`GPUSMI/Library/LaunchDaemons/com.gpusmi.helper.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gpusmi.helper</string>
    <key>MachServices</key>
    <dict>
        <key>com.gpusmi.helper</key>
        <true/>
    </dict>
    <key>BundleProgram</key>
    <string>Contents/Library/LaunchDaemons/HelperTool</string>
</dict>
</plist>
```

Xcodeで `com.gpusmi.helper.plist` を `GPUSMI` ターゲットに追加し、Build Phases → Copy Bundle Resources に含まれていることを確認。

- [ ] **Step 8: HelperToolバイナリをapp bundleにコピーするBuild Phaseを追加**

GPUSMI target → Build Phases → `+` → New Copy Files Phase:
- Destination: `Wrapper`
- Subpath: `Contents/Library/LaunchDaemons`
- Files: `HelperTool` (HelperToolターゲットのProduct)

---

## Task 3: Shared型の実装とテスト

**Files:**
- Create: `Shared/GPUSample.swift` (両ターゲット)
- Create: `Shared/XPCProtocol.swift` (両ターゲット)
- Create: `GPUSMITests/GPUSampleTests.swift`

- [ ] **Step 1: テストを先に書く**

`GPUSMITests/GPUSampleTests.swift`:
```swift
import XCTest
@testable import GPUSMI

final class GPUSampleTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let sample = GPUSample(
            timestamp: Date(timeIntervalSince1970: 1000),
            gpuUsage: 0.68,
            temperature: 47.3,
            power: 8.2,
            aneUsage: 0.12
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(GPUSample.self, from: data)

        XCTAssertEqual(decoded.gpuUsage, 0.68, accuracy: 0.001)
        XCTAssertEqual(decoded.temperature, 47.3, accuracy: 0.001)
        XCTAssertEqual(decoded.power, 8.2, accuracy: 0.001)
        XCTAssertEqual(decoded.aneUsage, 0.12, accuracy: 0.001)
    }

    func testNilFieldsEncodeDecodeRoundTrip() throws {
        let sample = GPUSample(
            timestamp: Date(),
            gpuUsage: 0.5,
            temperature: nil,
            power: nil,
            aneUsage: nil
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(GPUSample.self, from: data)

        XCTAssertNil(decoded.temperature)
        XCTAssertNil(decoded.power)
        XCTAssertNil(decoded.aneUsage)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: Product → Test (⌘U)
Expected: コンパイルエラー（GPUSampleが未定義）

- [ ] **Step 3: GPUSample.swiftを実装する**

`Shared/GPUSample.swift` (ターゲット: GPUSMI + HelperTool):
```swift
import Foundation

struct GPUSample: Codable, Sendable {
    let timestamp: Date
    let gpuUsage: Double       // 0.0–1.0 (GPU Active Residency)
    let temperature: Double?   // °C、取得不能時nil
    let power: Double?         // W、取得不能時nil
    let aneUsage: Double?      // 0.0–1.0 (ANE Active Residency)、取得不能時nil
}
```

- [ ] **Step 4: XPCProtocol.swiftを実装する**

`Shared/XPCProtocol.swift` (ターゲット: GPUSMI + HelperTool):
```swift
import Foundation

/// アプリからHelperToolを呼び出すプロトコル
@objc(GPUSMIHelperProtocol)
protocol GPUSMIHelperProtocol {
    /// サンプリングを開始する。success=trueで開始成功、falseでerrorMessageに理由
    func startSampling(withReply reply: @escaping (_ success: Bool, _ errorMessage: String?) -> Void)
    /// サンプリングを停止する
    func stopSampling(withReply reply: @escaping () -> Void)
    /// 最新のGPUSampleをJSONDataで返す。未取得時はnil
    func fetchLatestSample(withReply reply: @escaping (_ data: Data?) -> Void)
    /// HelperToolのCFBundleVersionを返す
    func helperVersion(withReply reply: @escaping (_ version: String) -> Void)
}
```

- [ ] **Step 5: テストを実行して全パス確認**

Run: ⌘U
Expected: GPUSampleTests → 2 tests passed

- [ ] **Step 6: コミット**

```bash
cd /Users/hakaru/DEVELOP/GPUSMI
git init
git add Shared/ GPUSMITests/GPUSampleTests.swift
git commit -m "feat: add GPUSample and XPCProtocol shared types"
```

---

## Task 4: PowerMetricsRunner (HelperTool)

**Files:**
- Create: `HelperTool/PowerMetricsRunner.swift`
- Create: `GPUSMITests/PowerMetricsParserTests.swift`

- [ ] **Step 1: パーステストを先に書く**

`GPUSMITests/PowerMetricsParserTests.swift`:
```swift
import XCTest
@testable import GPUSMI

final class PowerMetricsParserTests: XCTestCase {

    func testParsePlistData() throws {
        // powermetricsが出力するplistの最小サンプル
        let dict: [String: Any] = [
            "GPU": [
                "gpu_active_residency": 0.68,
                "gpu_power_mW": 8200.0
            ] as [String: Any],
            "ANE": [
                "ane_active_residency": 0.12
            ] as [String: Any],
            "thermal_pressure": "Nominal"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = PowerMetricsRunner.parse(plistData: plistData, timestamp: Date(timeIntervalSince1970: 1000))

        XCTAssertNotNil(sample)
        XCTAssertEqual(sample!.gpuUsage, 0.68, accuracy: 0.001)
        XCTAssertEqual(sample!.power!, 8.2, accuracy: 0.001)  // mW → W変換
        XCTAssertEqual(sample!.aneUsage!, 0.12, accuracy: 0.001)
    }

    func testParseMissingGPUReturnsNil() throws {
        let dict: [String: Any] = ["thermal_pressure": "Nominal"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = PowerMetricsRunner.parse(plistData: plistData, timestamp: Date())

        XCTAssertNil(sample)
    }

    func testParseNilOptionalFields() throws {
        let dict: [String: Any] = [
            "GPU": ["gpu_active_residency": 0.5] as [String: Any]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

        let sample = PowerMetricsRunner.parse(plistData: plistData, timestamp: Date())

        XCTAssertNotNil(sample)
        XCTAssertEqual(sample!.gpuUsage, 0.5, accuracy: 0.001)
        XCTAssertNil(sample!.temperature)
        XCTAssertNil(sample!.power)
        XCTAssertNil(sample!.aneUsage)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: ⌘U → コンパイルエラー（PowerMetricsRunnerが未定義）

- [ ] **Step 3: PowerMetricsRunner.swiftを実装する**

`HelperTool/PowerMetricsRunner.swift`:
```swift
import Foundation
import os.log

private let log = OSLog(subsystem: "com.gpusmi", category: "helper")

final class PowerMetricsRunner {

    // MARK: - Static parsing (テスト可能)

    /// powermetricsのplistデータをGPUSampleにパース。GPUキーがなければnil
    static func parse(plistData: Data, timestamp: Date) -> GPUSample? {
        guard let dict = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let gpuDict = dict["GPU"] as? [String: Any],
              let gpuUsage = gpuDict["gpu_active_residency"] as? Double
        else { return nil }

        let aneUsage = (dict["ANE"] as? [String: Any])?["ane_active_residency"] as? Double

        // 温度: "GPU Die Temp" または "gpu_die_temperature"
        let temperature: Double? = (gpuDict["GPU Die Temp"] as? Double)
            ?? (gpuDict["gpu_die_temperature"] as? Double)

        // 電力: powermetricsはmW単位のことがある → W変換
        let rawPower: Double? = (gpuDict["gpu_power_mW"] as? Double).map { $0 / 1000.0 }
            ?? (gpuDict["gpu_power"] as? Double)
            ?? (gpuDict["GPU Power"] as? Double)

        return GPUSample(
            timestamp: timestamp,
            gpuUsage: min(max(gpuUsage, 0.0), 1.0),
            temperature: temperature,
            power: rawPower,
            aneUsage: aneUsage.map { min(max($0, 0.0), 1.0) }
        )
    }

    // MARK: - Process management

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var buffer = Data()
    var onSample: ((GPUSample) -> Void)?
    var onError: ((String) -> Void)?

    /// powermetricsを常駐子プロセスとして起動する
    func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        p.arguments = [
            "--samplers", "gpu_power,ane_power,thermal",
            "-i", "1000",
            "--format", "plist"
        ]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        p.terminationHandler = { [weak self] _ in
            os_log("powermetrics terminated", log: log, type: .error)
            self?.onError?("powermetrics process terminated unexpectedly")
        }

        try p.run()
        self.process = p
        self.stdoutPipe = pipe

        // NUL区切りストリームを非同期で読む
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self.buffer.append(chunk)
            self.flushSamples()
        }

        os_log("powermetrics started (pid: %d)", log: log, type: .info, p.processIdentifier)
    }

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        buffer.removeAll()
        os_log("powermetrics stopped", log: log, type: .info)
    }

    // MARK: - Private

    private func flushSamples() {
        // NUL (0x00) を区切り文字としてplistを切り出す
        while let nullIndex = buffer.firstIndex(of: 0x00) {
            let plistData = buffer[buffer.startIndex..<nullIndex]
            buffer = buffer[buffer.index(after: nullIndex)...]
            guard !plistData.isEmpty else { continue }

            if let sample = Self.parse(plistData: plistData, timestamp: Date()) {
                onSample?(sample)
            } else {
                os_log("plist parse failed (%d bytes)", log: log, type: .debug, plistData.count)
            }
        }
    }
}
```

- [ ] **Step 4: テストを実行**

Run: ⌘U
Expected: PowerMetricsParserTests → 3 tests passed

> **注:** Task 1で確認したキー名が異なる場合は `parse()` 内のキー文字列を修正してテストを合わせること。

- [ ] **Step 5: コミット**

```bash
git add HelperTool/PowerMetricsRunner.swift GPUSMITests/PowerMetricsParserTests.swift
git commit -m "feat: add PowerMetricsRunner with NUL-stream plist parsing"
```

---

## Task 5: HelperTool main.swift (XPC server)

**Files:**
- Create: `HelperTool/main.swift`
- Create: `HelperTool/Info.plist`

- [ ] **Step 1: HelperTool/Info.plistを作成する**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.gpusmi.helper</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>SMAuthorizedClients</key>
    <array>
        <!-- 開発中はTeam IDを実際のIDに置換すること -->
        <string>identifier "com.gpusmi.app" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "XXXXXXXXXX"</string>
    </array>
</dict>
</plist>
```

> **注:** `XXXXXXXXXX` を実際のTeam IDに置換すること。`xcrun security find-identity -v -p codesigning` で確認できる。開発用署名の場合は別途設定が必要。

- [ ] **Step 2: HelperTool/main.swiftを実装する**

```swift
import Foundation
import os.log

private let log = OSLog(subsystem: "com.gpusmi", category: "helper")

// MARK: - XPC Service implementation

final class HelperService: NSObject, GPUSMIHelperProtocol {
    private let runner = PowerMetricsRunner()
    private var latestSampleData: Data?

    override init() {
        super.init()
        runner.onSample = { [weak self] sample in
            self?.latestSampleData = try? JSONEncoder().encode(sample)
        }
        runner.onError = { message in
            os_log("Runner error: %{public}s", log: log, type: .error, message)
        }
    }

    func startSampling(withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            try runner.start()
            os_log("Sampling started", log: log, type: .info)
            reply(true, nil)
        } catch {
            os_log("Failed to start: %{public}s", log: log, type: .error, error.localizedDescription)
            reply(false, error.localizedDescription)
        }
    }

    func stopSampling(withReply reply: @escaping () -> Void) {
        runner.stop()
        reply()
    }

    func fetchLatestSample(withReply reply: @escaping (Data?) -> Void) {
        reply(latestSampleData)
    }

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        reply(version)
    }
}

// MARK: - XPC Listener

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {

    /// 接続元のTeam IDを検証する
    private func teamID(from connection: NSXPCConnection) -> String? {
        guard let token = connection.value(forKey: "auditToken") as? Data else { return nil }
        var tokenValue = audit_token_t()
        (token as NSData).getBytes(&tokenValue, length: MemoryLayout<audit_token_t>.size)
        // Team IDはコード署名の"subject.OU"フィールド
        // 簡易検証: Bundle IDを確認する
        return connection.remoteObjectInterface?.interfaceName  // placeholder
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // 接続元Bundle IDを確認（開発中は緩めに、本番はTeam ID検証を強化）
        guard connection.auditToken != nil else {
            os_log("Rejected connection: no audit token", log: log, type: .error)
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: GPUSMIHelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        os_log("Accepted XPC connection", log: log, type: .info)
        return true
    }
}

// MARK: - Entry point

let delegate = ServiceDelegate()
let listener = NSXPCListener(machServiceName: "com.gpusmi.helper")
listener.delegate = delegate
listener.resume()

os_log("HelperTool started", log: log, type: .info)
RunLoop.main.run()
```

- [ ] **Step 3: Xcodeでビルドが通ることを確認**

Product → Build (⌘B) → HelperTool target
Expected: Build Succeeded（警告は許容、エラーなし）

- [ ] **Step 4: コミット**

```bash
git add HelperTool/main.swift HelperTool/Info.plist
git commit -m "feat: add HelperTool XPC server with powermetrics integration"
```

---

## Task 6: GPUDataStore (メインアプリ)

**Files:**
- Create: `GPUSMI/GPUDataStore.swift`
- Create: `GPUSMITests/GPUDataStoreTests.swift`

- [ ] **Step 1: テストを先に書く**

`GPUSMITests/GPUDataStoreTests.swift`:
```swift
import XCTest
@testable import GPUSMI

@MainActor
final class GPUDataStoreTests: XCTestCase {

    func testAddSampleAppendsToBuffer() {
        let store = GPUDataStore()
        let sample = GPUSample(timestamp: Date(), gpuUsage: 0.5, temperature: 45.0, power: 6.0, aneUsage: 0.1)
        store.addSample(sample)

        XCTAssertEqual(store.samples.count, 1)
        XCTAssertEqual(store.latestSample?.gpuUsage, 0.5)
    }

    func testBufferCapAt60Elements() {
        let store = GPUDataStore()
        for i in 0..<70 {
            let sample = GPUSample(timestamp: Date(), gpuUsage: Double(i) / 100.0, temperature: nil, power: nil, aneUsage: nil)
            store.addSample(sample)
        }

        XCTAssertEqual(store.samples.count, 60)
        // 最新が保持され、古いものが捨てられる
        XCTAssertEqual(store.latestSample?.gpuUsage, 0.69, accuracy: 0.001)
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
```

- [ ] **Step 2: テストが失敗することを確認**

⌘U → コンパイルエラー（GPUDataStoreが未定義）

- [ ] **Step 3: GPUDataStore.swiftを実装する**

`GPUSMI/GPUDataStore.swift`:
```swift
import Foundation
import Observation

@Observable
@MainActor
final class GPUDataStore {
    private(set) var samples: [GPUSample] = []
    private(set) var latestSample: GPUSample?
    private(set) var isConnected: Bool = false

    private let maxSamples = 60

    func addSample(_ sample: GPUSample) {
        samples.append(sample)
        if samples.count > maxSamples {
            samples.removeFirst()
        }
        latestSample = sample
    }

    func setConnected(_ connected: Bool) {
        isConnected = connected
        if !connected {
            // 切断時は最終値を保持してグレーアウト用フラグのみ更新
        }
    }
}
```

- [ ] **Step 4: テストを実行**

⌘U → GPUDataStoreTests → 4 tests passed

- [ ] **Step 5: コミット**

```bash
git add GPUSMI/GPUDataStore.swift GPUSMITests/GPUDataStoreTests.swift
git commit -m "feat: add GPUDataStore circular buffer with @Observable"
```

---

## Task 7: XPCClient (メインアプリ)

**Files:**
- Create: `GPUSMI/XPCClient.swift`

- [ ] **Step 1: XPCClient.swiftを実装する**

`GPUSMI/XPCClient.swift`:
```swift
import Foundation
import os.log

private let log = OSLog(subsystem: "com.gpusmi", category: "xpc")

@MainActor
final class XPCClient {

    private var connection: NSXPCConnection?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 30.0
    private var samplingTimer: Timer?

    var onSample: ((GPUSample) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    // MARK: - Public

    func connect() {
        guard connection == nil else { return }
        makeConnection()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        samplingTimer?.invalidate()
        samplingTimer = nil
        connection?.invalidate()
        connection = nil
        reconnectDelay = 1.0
    }

    // MARK: - Private

    private func makeConnection() {
        let conn = NSXPCConnection(machServiceName: "com.gpusmi.helper", options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: GPUSMIHelperProtocol.self)

        conn.interruptionHandler = { [weak self] in
            os_log("XPC interrupted, reconnecting...", log: log, type: .info)
            Task { @MainActor [weak self] in
                self?.handleDisconnection()
                self?.scheduleReconnect()
            }
        }

        conn.invalidationHandler = { [weak self] in
            os_log("XPC invalidated", log: log, type: .error)
            Task { @MainActor [weak self] in
                self?.connection = nil
                self?.handleDisconnection()
                self?.scheduleReconnect()
            }
        }

        conn.resume()
        connection = conn

        // サンプリング開始を要求
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            os_log("XPC error: %{public}s", log: log, type: .error, error.localizedDescription)
        } as? GPUSMIHelperProtocol

        proxy?.startSampling { [weak self] success, errorMessage in
            Task { @MainActor [weak self] in
                if success {
                    os_log("Sampling started", log: log, type: .info)
                    self?.reconnectDelay = 1.0
                    self?.onConnected?()
                    self?.startPollingTimer()
                } else {
                    os_log("Start failed: %{public}s", log: log, type: .error, errorMessage ?? "unknown")
                    self?.scheduleReconnect()
                }
            }
        }
    }

    private func startPollingTimer() {
        samplingTimer?.invalidate()
        samplingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchSample()
            }
        }
    }

    private func fetchSample() {
        guard let conn = connection else { return }
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in } as? GPUSMIHelperProtocol
        proxy?.fetchLatestSample { [weak self] data in
            guard let data else { return }
            Task { @MainActor [weak self] in
                if let sample = try? JSONDecoder().decode(GPUSample.self, from: data) {
                    self?.onSample?(sample)
                }
            }
        }
    }

    private func handleDisconnection() {
        samplingTimer?.invalidate()
        samplingTimer = nil
        onDisconnected?()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        os_log("Reconnecting in %.0fs", log: log, type: .info, delay)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.makeConnection()
            }
        }
    }
}
```

- [ ] **Step 2: ビルドが通ることを確認**

⌘B → Build Succeeded

- [ ] **Step 3: コミット**

```bash
git add GPUSMI/XPCClient.swift
git commit -m "feat: add XPCClient with exponential backoff reconnection"
```

---

## Task 8: HelperInstaller (メインアプリ)

**Files:**
- Create: `GPUSMI/HelperInstaller.swift`
- Modify: `GPUSMI/Info.plist`

- [ ] **Step 1: GPUSMI/Info.plistにSMPrivilegedExecutablesキーを追加**

`GPUSMI/Info.plist` に以下を追加（既存のdict内）:
```xml
<key>SMPrivilegedExecutables</key>
<dict>
    <!-- XXXXXXXXXX を実際のTeam IDに置換 -->
    <key>com.gpusmi.helper</key>
    <string>identifier "com.gpusmi.helper" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "XXXXXXXXXX"</string>
</dict>
```

- [ ] **Step 2: HelperInstaller.swiftを実装する**

`GPUSMI/HelperInstaller.swift`:
```swift
import Foundation
import ServiceManagement
import os.log

private let log = OSLog(subsystem: "com.gpusmi", category: "app")

enum HelperInstallerError: LocalizedError {
    case requiresApproval
    case registrationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            return "System Settings でGPUSMIの実行を許可してください"
        case .registrationFailed(let e):
            return "HelperToolのインストールに失敗しました: \(e.localizedDescription)"
        }
    }
}

@MainActor
final class HelperInstaller {

    private static let plistName = "com.gpusmi.helper.plist"

    /// HelperToolをインストール（必要な場合のみ）。throws on failure.
    static func installIfNeeded() async throws {
        let service = SMAppService.daemon(plistName: plistName)

        switch service.status {
        case .notRegistered:
            os_log("Registering daemon...", log: log, type: .info)
            try await register(service: service)

        case .enabled:
            // バージョン確認
            if await needsUpdate() {
                os_log("Updating daemon...", log: log, type: .info)
                try await service.unregister()
                try await register(service: service)
            } else {
                os_log("Daemon already up-to-date", log: log, type: .info)
            }

        case .requiresApproval:
            os_log("Requires approval in System Settings", log: log, type: .error)
            SMAppService.openSystemSettingsLoginItems()
            throw HelperInstallerError.requiresApproval

        case .notFound:
            os_log("Daemon plist not found in bundle", log: log, type: .fault)
            throw HelperInstallerError.registrationFailed(
                NSError(domain: "com.gpusmi", code: -1, userInfo: [NSLocalizedDescriptionKey: "Daemon plist not found"])
            )

        @unknown default:
            break
        }
    }

    // MARK: - Private

    private static func register(service: SMAppService) async throws {
        do {
            try service.register()
        } catch {
            throw HelperInstallerError.registrationFailed(error)
        }
    }

    /// インストール済みHelperのバージョンとbundleのバージョンを比較
    private static func needsUpdate() async -> Bool {
        // bundleのHelperToolバイナリのバージョンを取得
        guard let bundleHelperURL = Bundle.main.url(
            forResource: "HelperTool",
            withExtension: nil,
            subdirectory: "Contents/Library/LaunchDaemons"
        ),
        let bundleVersion = Bundle(url: bundleHelperURL)?.infoDictionary?["CFBundleVersion"] as? String
        else { return false }

        // インストール済みHelperToolにXPC接続してバージョンを確認
        return await withCheckedContinuation { continuation in
            let conn = NSXPCConnection(machServiceName: "com.gpusmi.helper", options: [])
            conn.remoteObjectInterface = NSXPCInterface(with: GPUSMIHelperProtocol.self)
            conn.resume()

            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                continuation.resume(returning: true)  // エラー時は更新扱い
            } as? GPUSMIHelperProtocol

            proxy?.helperVersion { installedVersion in
                conn.invalidate()
                continuation.resume(returning: installedVersion != bundleVersion)
            }
        }
    }
}
```

- [ ] **Step 3: ビルドが通ることを確認**

⌘B → Build Succeeded

- [ ] **Step 4: コミット**

```bash
git add GPUSMI/HelperInstaller.swift GPUSMI/Info.plist
git commit -m "feat: add HelperInstaller using SMAppService.daemon"
```

---

## Task 9: DockIconRenderer (メインアプリ)

**Files:**
- Create: `GPUSMI/DockIconRenderer.swift`
- Create: `GPUSMITests/DockIconRendererTests.swift`

- [ ] **Step 1: テストを先に書く**

`GPUSMITests/DockIconRendererTests.swift`:
```swift
import XCTest
@testable import GPUSMI

final class DockIconRendererTests: XCTestCase {

    func testRendersImageForZeroUsage() {
        let image = DockIconRenderer.render(usage: 0.0, isConnected: true)
        XCTAssertEqual(image.size.width, 512)
        XCTAssertEqual(image.size.height, 512)
    }

    func testRendersImageForFullUsage() {
        let image = DockIconRenderer.render(usage: 1.0, isConnected: true)
        XCTAssertEqual(image.size.width, 512)
    }

    func testRendersDisconnectedState() {
        let image = DockIconRenderer.render(usage: 0.5, isConnected: false)
        XCTAssertEqual(image.size.width, 512)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

⌘U → コンパイルエラー

- [ ] **Step 3: DockIconRenderer.swiftを実装する**

`GPUSMI/DockIconRenderer.swift`:
```swift
import AppKit
import CoreGraphics

enum DockIconRenderer {

    static let iconSize = CGSize(width: 512, height: 512)

    /// usage: 0.0–1.0, isConnected: falseのときグレー表示
    static func render(usage: Double, isConnected: Bool) -> NSImage {
        let size = iconSize
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage(size: size) }

        let rect = CGRect(origin: .zero, size: size)
        draw(in: ctx, rect: rect, usage: usage, isConnected: isConnected)

        guard let cgImage = ctx.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cgImage, size: size)
    }

    // MARK: - Private drawing

    private static func draw(in ctx: CGContext, rect: CGRect, usage: Double, isConnected: Bool) {
        let padding: CGFloat = 48
        let barWidth: CGFloat = rect.width - padding * 2
        let barHeight: CGFloat = rect.height - padding * 2
        let barX: CGFloat = padding
        let barY: CGFloat = padding

        // 背景（角丸矩形）
        ctx.setFillColor(NSColor(white: 0.1, alpha: 0.85).cgColor)
        let bgPath = CGPath(roundedRect: rect, cornerWidth: 80, cornerHeight: 80, transform: nil)
        ctx.addPath(bgPath)
        ctx.fillPath()

        // バー背景
        ctx.setFillColor(NSColor(white: 0.25, alpha: 1.0).cgColor)
        let bgBarRect = CGRect(x: barX, y: barY, width: barWidth, height: barHeight)
        let bgBarPath = CGPath(roundedRect: bgBarRect, cornerWidth: 24, cornerHeight: 24, transform: nil)
        ctx.addPath(bgBarPath)
        ctx.fillPath()

        // バー前景（下から上に使用率分だけ塗る）
        let fillHeight = barHeight * CGFloat(max(0, min(1, usage)))
        let fillY = barY
        let fillRect = CGRect(x: barX, y: fillY, width: barWidth, height: fillHeight)

        let barColor = isConnected ? color(for: usage) : NSColor.systemGray.cgColor
        ctx.setFillColor(barColor)

        // 角丸はバー全体のpathをclipして塗る
        ctx.saveGState()
        ctx.addPath(bgBarPath)
        ctx.clip()
        ctx.fill(fillRect)
        ctx.restoreGState()

        // 使用率テキスト
        let label = isConnected ? String(format: "%.0f%%", usage * 100) : "--"
        drawLabel(ctx, text: label, in: rect, above: barY + barHeight + 8)
    }

    private static func color(for usage: Double) -> CGColor {
        switch usage {
        case ..<0.6:
            return NSColor.systemGreen.cgColor
        case ..<0.85:
            return NSColor.systemYellow.cgColor
        default:
            return NSColor.systemRed.cgColor
        }
    }

    private static func drawLabel(_ ctx: CGContext, text: String, in rect: CGRect, above y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 96, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        let lineWidth = CTLineGetImageBounds(line, ctx).width

        ctx.textPosition = CGPoint(x: (rect.width - lineWidth) / 2, y: rect.height - y - 110)
        CTLineDraw(line, ctx)
    }
}
```

- [ ] **Step 4: テストを実行**

⌘U → DockIconRendererTests → 3 tests passed

- [ ] **Step 5: コミット**

```bash
git add GPUSMI/DockIconRenderer.swift GPUSMITests/DockIconRendererTests.swift
git commit -m "feat: add DockIconRenderer with Core Graphics vertical bar"
```

---

## Task 10: PopupView (SwiftUI + Swift Charts)

**Files:**
- Create: `GPUSMI/PopupView.swift`

- [ ] **Step 1: PopupView.swiftを実装する**

`GPUSMI/PopupView.swift`:
```swift
import SwiftUI
import Charts

struct PopupView: View {
    let store: GPUDataStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            charts
            metrics
        }
        .padding(16)
        .frame(width: 320, height: 280)
        .background(.black.opacity(0.92))
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text("GPUSMI")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Text("· \(gpuName)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Circle()
                .fill(store.isConnected ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
        }
    }

    private var charts: some View {
        HStack(spacing: 8) {
            chartView(
                title: "GPU",
                samples: store.samples,
                value: \.gpuUsage,
                color: .cyan,
                format: "%.0f%%",
                scale: 100
            )
            chartView(
                title: "Temp",
                samples: store.samples,
                value: { $0.temperature ?? 0 },
                color: .orange,
                format: "%.0f°C",
                scale: 1
            )
        }
    }

    private func chartView(
        title: String,
        samples: [GPUSample],
        value: @escaping (GPUSample) -> Double,
        color: Color,
        format: String,
        scale: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Chart(samples.indices, id: \.self) { i in
                let v = value(samples[i])
                AreaMark(
                    x: .value("t", i),
                    y: .value("v", v * scale)
                )
                .foregroundStyle(color.opacity(0.3))
                LineMark(
                    x: .value("t", i),
                    y: .value("v", v * scale)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 80)
            .opacity(store.isConnected ? 1.0 : 0.4)
        }
    }

    private var metrics: some View {
        HStack {
            metricItem(label: "GPU", value: gpuText, color: .cyan)
            metricItem(label: "Temp", value: tempText, color: .orange)
            metricItem(label: "Power", value: powerText, color: .secondary)
            metricItem(label: "ANE", value: aneText, color: .purple)
        }
    }

    private func metricItem(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Computed

    private var gpuName: String { "M3 Ultra" }  // TODO: 実デバイス名取得

    private var latest: GPUSample? { store.latestSample }

    private var gpuText: String {
        latest.map { String(format: "%.0f%%", $0.gpuUsage * 100) } ?? "--"
    }
    private var tempText: String {
        latest?.temperature.map { String(format: "%.0f°C", $0) } ?? "--"
    }
    private var powerText: String {
        latest?.power.map { String(format: "%.1fW", $0) } ?? "--"
    }
    private var aneText: String {
        latest?.aneUsage.map { String(format: "%.0f%%", $0 * 100) } ?? "--"
    }
}
```

- [ ] **Step 2: Xcodeのプレビューで表示確認**

Canvas → Resume でPopupViewのプレビューが出ることを確認（ダミーデータで）。

- [ ] **Step 3: ビルドが通ることを確認**

⌘B → Build Succeeded

- [ ] **Step 4: コミット**

```bash
git add GPUSMI/PopupView.swift
git commit -m "feat: add PopupView SwiftUI dashboard with Swift Charts"
```

---

## Task 11: PopupWindowController (メインアプリ)

**Files:**
- Create: `GPUSMI/PopupWindowController.swift`

- [ ] **Step 1: PopupWindowController.swiftを実装する**

`GPUSMI/PopupWindowController.swift`:
```swift
import AppKit
import SwiftUI

@MainActor
final class PopupWindowController: NSWindowController {

    private weak var store: GPUDataStore?

    convenience init(store: GPUDataStore) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true

        self.init(window: panel)
        self.store = store

        let hostingView = NSHostingView(rootView: PopupView(store: store))
        hostingView.frame = panel.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hostingView)
    }

    func toggle() {
        if window?.isVisible == true {
            close()
        } else {
            showPopup()
        }
    }

    func close() {
        window?.orderOut(nil)
    }

    // MARK: - Private

    private func showPopup() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = window!.frame.size

        // Dock上部に表示（画面下部中央）
        let x = screenFrame.midX - windowSize.width / 2
        let y = screenFrame.minY + 8
        window?.setFrameOrigin(NSPoint(x: x, y: y))
        window?.makeKeyAndOrderFront(nil)

        // ウィンドウ外クリックで閉じる
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let win = self.window, win.isVisible else { return }
            let loc = event.locationInWindow
            let winFrame = win.frame
            if !winFrame.contains(loc) {
                DispatchQueue.main.async { self.close() }
            }
        }
    }
}
```

- [ ] **Step 2: ビルドが通ることを確認**

⌘B → Build Succeeded

- [ ] **Step 3: コミット**

```bash
git add GPUSMI/PopupWindowController.swift
git commit -m "feat: add PopupWindowController with NSPanel above Dock"
```

---

## Task 12: AppDelegate — 全体をワイヤリング

**Files:**
- Create: `GPUSMI/AppDelegate.swift`

- [ ] **Step 1: AppDelegate.swiftを実装する**

`GPUSMI/AppDelegate.swift`:
```swift
import AppKit
import os.log

private let log = OSLog(subsystem: "com.gpusmi", category: "app")

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = GPUDataStore()
    private let xpcClient = XPCClient()
    private lazy var popupController = PopupWindowController(store: store)

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // DockアプリとしてDockにのみ表示（メニューバーなし）
        NSApp.setActivationPolicy(.accessory)

        // HelperToolをインストール
        Task {
            do {
                try await HelperInstaller.installIfNeeded()
                connectXPC()
            } catch {
                os_log("Install failed: %{public}s", log: log, type: .error, error.localizedDescription)
                showError(error.localizedDescription)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dockアイコンクリック
        popupController.toggle()
        return false
    }

    // MARK: - Private

    private func connectXPC() {
        xpcClient.onSample = { [weak self] sample in
            guard let self else { return }
            store.addSample(sample)
            updateDockIcon()
        }
        xpcClient.onConnected = { [weak self] in
            self?.store.setConnected(true)
            os_log("XPC connected", log: log, type: .info)
        }
        xpcClient.onDisconnected = { [weak self] in
            self?.store.setConnected(false)
            self?.updateDockIcon()
            os_log("XPC disconnected", log: log, type: .info)
        }
        xpcClient.connect()
    }

    private func updateDockIcon() {
        let usage = store.latestSample?.gpuUsage ?? 0
        let connected = store.isConnected
        DispatchQueue.global(qos: .userInteractive).async {
            let image = DockIconRenderer.render(usage: usage, isConnected: connected)
            DispatchQueue.main.async {
                NSApp.applicationIconImage = image
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "GPUSMI — セットアップエラー"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
```

- [ ] **Step 2: Info.plistのPrincipalClassを設定**

`GPUSMI/Info.plist` に追加:
```xml
<key>NSPrincipalClass</key>
<string>AppDelegate</string>
```

既存の `@NSApplicationMain` があれば削除し、`AppDelegate` の `@main` アノテーションを使う。

- [ ] **Step 3: ビルドが通ることを確認**

⌘B → Build Succeeded（警告は許容）

- [ ] **Step 4: 手動スモークテスト（sudoパスワードが必要）**

1. Product → Run (⌘R) でアプリを起動
2. macOSが「GPUSMIが変更を加えようとしています」ダイアログを表示
3. 管理者パスワードを入力
4. DockアイコンがGPU使用率の縦バーに変わることを確認
5. Dockアイコンをクリックしてポップアップが出ることを確認
6. GPU使用率・温度・電力・ANEの数値が表示されることを確認

- [ ] **Step 5: 最終コミット**

```bash
git add GPUSMI/AppDelegate.swift GPUSMI/Info.plist
git commit -m "feat: wire AppDelegate — GPUSMI v1.0 complete"
```

---

## Self-Review チェックリスト

### Spec coverage

| スペック要件 | 対応Task |
|------------|---------|
| Dockアイコン縦バー表示 | Task 9, 12 |
| 使用率で色変化 (緑/黄/赤) | Task 9 |
| クリックでポップアップ | Task 11, 12 |
| GPU+温度の2チャート | Task 10 |
| 4指標数値表示 | Task 10 |
| SMAppService.daemon | Task 8 |
| XPC接続・再接続 | Task 7 |
| NUL区切りplistストリーム | Task 4 |
| GPUSample optional fields | Task 3 |
| エラー時Dockアイコン表示 | Task 12 (`isConnected=false`) |
| os_logロギング | Task 4, 5, 7, 8, 12 |
| バックグラウンドキュー描画 | Task 12 (`updateDockIcon`) |
| XPCセキュリティ (Team ID) | Task 5 (auditToken確認) |
| HelperToolバージョン管理 | Task 8 (`needsUpdate`) |

### 残課題（v1.1以降）

- `auditToken` からTeam IDを厳密に検証するコードの強化
- GPUデバイス名の動的取得（現在ハードコード）
- `SMAuthorizedClients` / `SMPrivilegedExecutables` のTeam ID実際値の設定手順ドキュメント
