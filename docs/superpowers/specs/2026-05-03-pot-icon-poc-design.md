# Pot Icon PoC — 設計仕様

**日付:** 2026-05-03
**対象:** MacSlowCooker Dock アイコンの「鍋＋火力」ビジュアル化 PoC

---

## 1. 概要

現状の Dock アイコンは GPU 使用率を縦バーで表示する無機質なメーター。これを「直火にかけた煮込み鍋」ビジュアルに置き換え、ブランド「MacSlowCooker」の世界観を Dock の常駐領域で表現する。本 PoC は単一の鍋スタイル（ダッチオーブン）を完成させ、将来のスタイル追加（おでん土鍋・カレー鍋など）と設定 UI の土台を作る。

**PoC スコープ:**
- ダッチオーブン + 直下の炎によるアイコン描画
- GPU 使用率に応じた炎の高さ・色・湯気の変化
- 高負荷／高熱時の沸騰演出（蓋ガタガタ + 赤い湯気）
- 補間アニメーション・炎ゆらぎアニメーションの実装
- ユーザー設定ウィンドウ（鍋スタイル / 炎モード / 沸騰トリガー）

**スコープ外（Phase 2 以降）:**
- ダッチオーブン以外の鍋スタイル（プロトコルだけ用意）
- ロケール検出 / 表示名切り替え
- per-process GPU 使用率の取得・表示（具材プカプカ）
- スナップショット（ピクセル一致）テスト

---

## 2. アーキテクチャ

```
┌────────────── XPCClient (existing) ──────────────┐
│  GPUSample @ 1Hz                                 │
└──────────────────┬───────────────────────────────┘
                   ↓
            GPUDataStore (existing)
                   ↓
            AppDelegate.onSample(_:)
                   ↓
       ┌───────────────────────┐
       │ DockIconAnimator (NEW) │  ← Settings (NEW, @Observable)
       │  ├─ displayedUsage    │     ↑
       │  ├─ wigglePhase       │     │ ⌘,
       │  └─ boilingState      │     │
       └───────────┬───────────┘  PreferencesWindowController (NEW)
                   ↓ IconState
       ┌───────────────────────┐
       │ PotRenderer (protocol) │
       │  └─ DutchOvenRenderer  │
       └───────────┬───────────┘
                   ↓ NSImage
            NSApp.applicationIconImage
```

**データフロー:**
1. `XPCClient.onSample` → `AppDelegate` → `Animator.update(sample:)` → `targetUsage` 更新
2. Animator 内部の Timer (10fps) が tick ごとに状態を更新し `IconState` を生成
3. 現在の `Settings.potStyle` に対応するレンダラ (`DutchOvenRenderer`) で `NSImage` 描画
4. `NSApp.applicationIconImage` に代入
5. 静止状態（補間完了 + wiggle 無効 + boiling フェード完了）になったら Timer を自己停止 → CPU 0%
6. Settings 変更時は `@Observable` 経由で Animator が再評価し、必要なら Timer 再起動

---

## 3. データ型

### 3.1 設定型

```swift
enum PotStyle: String, CaseIterable, Codable {
    case dutchOven = "dutchOven"
    // 将来: case oden, curry, saucepan
}

enum FlameAnimation: String, CaseIterable, Codable {
    case none           // サンプル駆動のみ、サンプル間は静止
    case interpolation  // 高さ補間のみ
    case wiggle         // ゆらぎのみ（高さは即時 target）
    case both           // 補間 + ゆらぎ
}

enum BoilingTrigger: String, CaseIterable, Codable {
    case temperature       // temp ≥ 85°C
    case thermalPressure   // thermalPressure ∈ {Serious, Critical}
    case combined          // (usage ≥ 90% × 5s) OR thermalPressure ≥ Serious  ← default
}
```

### 3.2 Settings (永続ストア)

```swift
@Observable
final class Settings {
    var potStyle: PotStyle
    var flameAnimation: FlameAnimation
    var boilingTrigger: BoilingTrigger

    static let shared = Settings()

    private init() { /* UserDefaults から復元、不正値はデフォルトにフォールバック */ }
}
```

- シングルトン (`Settings.shared`) を `AppDelegate` と `PreferencesWindowController` で共有
- 各 setter で UserDefaults に永続化（kvo / didSet 相当）
- デフォルト値: `.dutchOven` / `.both` / `.combined`

### 3.3 IconState (レンダラ入力)

```swift
struct IconState {
    let displayedUsage: Double      // [0, 1] 補間後
    let temperature: Double?         // 表示用 (nil 可)
    let isConnected: Bool

    let flameWigglePhase: Double     // [0, 2π) wiggle 無効なら 0 固定
    let flameWiggleEnabled: Bool

    let isBoiling: Bool
    let boilingIntensity: Double     // [0, 1] フェード値
}
```

レンダラは値型 `IconState` を受け取る純関数として実装。テストで自由に状態を構築可能。

---

## 4. DutchOvenRenderer

### 4.1 描画する 5 状態

| 状態 | トリガー | 見た目 |
|---|---|---|
| Disconnected | `isConnected == false` | グレー鍋・炎なし・"--" 文字 |
| Idle | `usage < 0.2` | とろ火・湯気なし |
| Simmer | `0.2 ≤ usage < 0.6` | 中火・湯気1本 |
| High | `0.6 ≤ usage < 0.9` | 強火・湯気2本 |
| Boiling | `boilingIntensity > 0` | 蓋ガタガタ + 赤い湯気（強度フェード） |

### 4.2 連続パラメータマッピング

- **flame height**: `displayedUsage` に線形比例（0% → 0px、100% → 60px @ 512×512）
- **flame width**: `sqrt(displayedUsage)` に比例（広がり方の自然さ）
- **flame color**: `displayedUsage < 0.6` で黄〜オレンジ、`≥ 0.85` で赤の比率増加
- **steam count**: 4.1 の状態に対応して 0/1/2/3 ストランド（Idle=0, Simmer=1, High=2, Boiling 時は基本2本 + boilingIntensity フェードで3本目を加算）
- **steam color**: `boilingIntensity` で白 → オレンジ赤 へ補間
- **lid offset**: `boilingIntensity × sin(wigglePhase × 8) × 3px`
- **flame shape wiggle**: `flameWiggleEnabled` 時、ベジェ制御点を `sin(wigglePhase + offset)` で歪ませる

### 4.3 描画スタック

`Core Graphics` (CGContext) で 512×512 のビットマップを生成し `NSImage` として返す。SwiftUI / Metal は使わない（既存の `DockIconRenderer` と同じスタック）。

---

## 5. DockIconAnimator

### 5.1 状態

```swift
@MainActor
final class DockIconAnimator {
    private let settings: Settings
    private let renderer: PotRenderer.Type
    private let clock: any Clock

    // 補間状態
    private var displayedUsage: Double = 0
    private var targetUsage: Double = 0

    // wiggle 状態
    private var wigglePhase: Double = 0

    // 沸騰状態
    private var aboveThresholdSince: Date?  // .combined の 5秒持続判定用
    private var isBoiling: Bool = false
    private var boilingIntensity: Double = 0

    // 接続/サンプル
    private var isConnected: Bool = false
    private var latestSample: GPUSample?

    private var timer: Timer?
}
```

### 5.2 定数

- `tickInterval = 1.0 / 10.0` （10 fps）
- `interpolationTimeConstant = 0.4` 秒（指数 lerp、0.4 秒で 63% 到達）
- `boilingFadeTimeConstant = 0.6` 秒
- `wiggleSpeed = 4.0` rad/s

### 5.3 公開 API

```swift
init(settings: Settings = .shared,
     renderer: PotRenderer.Type = DutchOvenRenderer.self,
     clock: any Clock = SystemClock())

func update(sample: GPUSample)        // XPC からのサンプル
func setConnected(_ connected: Bool)  // 接続状態変化
func settingsDidChange()              // @Observable 変更通知の受け口
```

### 5.4 tick ロジック（疑似コード）

```
dt = tickInterval
α  = 1 - exp(-dt / interpolationTimeConstant)
displayedUsage += (targetUsage - displayedUsage) * α

if settings.flameAnimation in [.wiggle, .both] {
    wigglePhase = (wigglePhase + dt * wiggleSpeed) mod 2π
}

βb = 1 - exp(-dt / boilingFadeTimeConstant)
boilingTarget = isBoiling ? 1.0 : 0.0
boilingIntensity += (boilingTarget - boilingIntensity) * βb

state = IconState(
    displayedUsage:     displayedUsage,
    temperature:        latestSample?.temperature,
    isConnected:        isConnected,
    flameWigglePhase:   wigglePhase,
    flameWiggleEnabled: settings.flameAnimation in [.wiggle, .both],
    isBoiling:          isBoiling,
    boilingIntensity:   boilingIntensity)

NSApp.applicationIconImage = renderer.render(state: state)

// 自己停止
if !needsAnimation() { timer.invalidate(); timer = nil }
```

### 5.5 `needsAnimation()` 条件

タイマー継続条件（OR 結合）:
- `settings.flameAnimation in [.wiggle, .both]`（常時アニメ）
- `|displayedUsage - targetUsage| > 0.005`（補間中）
- `|boilingIntensity - boilingTarget| > 0.005`（フェード中）

いずれも false → タイマー停止 → 次の `update()` / `setConnected()` / `settingsDidChange()` まで CPU 0%。

### 5.6 沸騰判定

ロジックは**純関数として静的メソッドに切り出して**単体テスト可能にする。Animator の `evaluateBoiling()` はこの静的メソッドの薄いラッパー。

```swift
extension DockIconAnimator {
    /// 沸騰状態を計算する純関数。BoilingTriggerTests から直接テスト可能。
    static func computeBoiling(
        trigger: BoilingTrigger,
        sample: GPUSample,
        aboveThresholdSince: Date?,
        now: Date
    ) -> (isBoiling: Bool, newAboveThresholdSince: Date?) {
        switch trigger {
        case .temperature:
            return (isBoiling: (sample.temperature ?? 0) >= 85,
                    newAboveThresholdSince: nil)
        case .thermalPressure:
            return (isBoiling: ["Serious", "Critical"].contains(sample.thermalPressure ?? ""),
                    newAboveThresholdSince: nil)
        case .combined:
            let highUsage = sample.gpuUsage >= 0.9
            let newSince: Date? = highUsage ? (aboveThresholdSince ?? now) : nil
            let sustained = newSince.map { now.timeIntervalSince($0) >= 5.0 } ?? false
            let pressured = ["Serious", "Critical"].contains(sample.thermalPressure ?? "")
            return (isBoiling: sustained || pressured, newAboveThresholdSince: newSince)
        }
    }
}
```

Animator 側:
```swift
private func evaluateBoiling(sample: GPUSample) {
    let result = Self.computeBoiling(
        trigger: settings.boilingTrigger,
        sample: sample,
        aboveThresholdSince: aboveThresholdSince,
        now: clock.now)
    isBoiling = result.isBoiling
    aboveThresholdSince = result.newAboveThresholdSince
}
```

`settingsDidChange()` で `boilingTrigger` が `.combined` 以外に変わった場合は `aboveThresholdSince = nil` にリセットする。

---

## 6. PreferencesWindowController

### 6.1 ウィンドウ仕様

- `NSWindow` (titled + closable)、サイズ 380×220、center 配置
- タイトル: "MacSlowCooker 設定"
- コンテンツ: `NSHostingController` 経由の SwiftUI `PreferencesView`
- ウィンドウは lazy 生成、閉じても破棄せず再表示で同じインスタンス
- AppDelegate の ⌘, メニュー項目から起動

### 6.2 SwiftUI ビュー

```swift
struct PreferencesView: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Picker("鍋スタイル", selection: $settings.potStyle) {
                Text("ダッチオーブン").tag(PotStyle.dutchOven)
            }
            Picker("炎アニメーション", selection: $settings.flameAnimation) {
                Text("なし").tag(FlameAnimation.none)
                Text("補間のみ").tag(FlameAnimation.interpolation)
                Text("ゆらぎのみ").tag(FlameAnimation.wiggle)
                Text("両方").tag(FlameAnimation.both)
            }
            Picker("沸騰トリガー", selection: $settings.boilingTrigger) {
                Text("温度 ≥ 85°C").tag(BoilingTrigger.temperature)
                Text("熱ストレス ≥ Serious").tag(BoilingTrigger.thermalPressure)
                Text("組み合わせ（推奨）").tag(BoilingTrigger.combined)
            }
        }
        .padding(20)
        .formStyle(.grouped)
    }
}
```

### 6.3 メニュー連携

`AppDelegate.applicationDidFinishLaunching` で `NSApp.mainMenu` を手動構築:

- 「MacSlowCooker について」
- セパレータ
- 「設定…」 (⌘,)  → `showPreferences()`
- セパレータ
- 「MacSlowCooker を終了」 (⌘Q)

Storyboard / MainMenu.xib は使わない（既存 main.swift と同じ手動構築方針）。

---

## 7. AppDelegate 統合

### 7.1 改修点

```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = GPUDataStore()
    private let xpcClient = XPCClient()
    private let settings = Settings.shared
    private let animator = DockIconAnimator()

    private lazy var popupController = PopupWindowController(store: store)
    private var preferencesController: PreferencesWindowController?
    private var settingsObservation: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        observeSettings()
        animator.setConnected(false)  // 初回 Disconnected 描画
        Task { /* HelperInstaller → connectXPC */ }
    }

    private func connectXPC() {
        xpcClient.onSample = { [weak self] sample in
            self?.store.addSample(sample)
            self?.animator.update(sample: sample)
        }
        xpcClient.onConnected    = { [weak self] in self?.animator.setConnected(true) }
        xpcClient.onDisconnected = { [weak self] in self?.animator.setConnected(false) }
        xpcClient.connect()
    }

    private func observeSettings() {
        settingsObservation = Task { @MainActor in
            for await _ in settings.changes {
                animator.settingsDidChange()
            }
        }
    }
}
```

`Settings.changes` は `withObservationTracking` を再帰的に張り直す `AsyncStream<Void>`。

### 7.2 削除されるコード

- `private func updateDockIcon()`（Animator が肩代わり）
- `DockIconRenderer` の使用（ファイル自体も削除）

---

## 8. ファイル変更計画

### 8.1 削除

| ファイル | 理由 |
|---|---|
| `MacSlowCooker/DockIconRenderer.swift` | バー描画を完全置換 |
| `MacSlowCookerTests/DockIconRendererTests.swift` | レンダラごと差し替え |

### 8.2 改修

| ファイル | 変更内容 |
|---|---|
| `MacSlowCooker/AppDelegate.swift` | Animator/Settings 統合、メニュー構築、Preferences 起動 |

### 8.3 新規

| ファイル | 内容 |
|---|---|
| `MacSlowCooker/Settings.swift` | @Observable Settings + UserDefaults + AsyncStream changes |
| `MacSlowCooker/PotRenderer.swift` | `PotRenderer` protocol + `IconState` struct + 列挙型 |
| `MacSlowCooker/DutchOvenRenderer.swift` | ダッチオーブン CG 描画 |
| `MacSlowCooker/DockIconAnimator.swift` | アニメーションステートマシン + Timer |
| `MacSlowCooker/PreferencesWindowController.swift` | Preferences ウィンドウ + SwiftUI |
| `MacSlowCooker/Clock.swift` | `Clock` プロトコル + `SystemClock` (テスト注入用) |
| `MacSlowCookerTests/SettingsTests.swift` | デフォルト値、UserDefaults 永続化 |
| `MacSlowCookerTests/DockIconAnimatorTests.swift` | 補間、wiggle、沸騰ステートマシン |
| `MacSlowCookerTests/DutchOvenRendererTests.swift` | 主要状態のスモークテスト |
| `MacSlowCookerTests/BoilingTriggerTests.swift` | 3 モードの判定ロジック |

`project.yml` への影響なし（`MacSlowCooker/` 配下を再帰追加しているため）。`xcodegen generate` の再実行のみ必要。

---

## 9. テスト戦略

### 9.1 レイヤー別

| 対象 | アプローチ |
|---|---|
| `Settings` | 単体テスト（純ロジック）|
| `BoilingTrigger` 判定 | 単体テスト（表形式パラメータライズ）|
| `DockIconAnimator` | 単体テスト（`Clock` 注入で時間を決定的に）|
| `DutchOvenRenderer` | スモークテスト（クラッシュしない・non-empty 画像）|
| Preferences UI | 手動確認のみ |
| AppDelegate 統合 | 手動確認（実機ビルド + 操作） |

### 9.2 主要テストケース

**SettingsTests** (4 ケース)
- デフォルト値が `.dutchOven / .both / .combined`
- UserDefaults に書き込まれた値を起動時に読み戻す
- 不正な rawValue が入っている場合のフォールバック
- 各 setter が UserDefaults に永続化される

**BoilingTriggerTests** (~10 ケース)
- `.temperature`: temp = nil/50/85/90 × 期待値
- `.thermalPressure`: "Nominal"/"Fair"/"Serious"/"Critical" × 期待値
- `.combined`: usage 持続時間と thermalPressure の組み合わせ

**DockIconAnimatorTests** (~15 ケース、`TestClock` 注入)
- 補間: targetUsage = 1.0 で 10 tick 後に displayedUsage が 0.92 程度
- wiggle 無効でアイドル状態 → タイマー自己停止
- wiggle 有効 → タイマー継続
- 沸騰フェードイン: isBoiling true で 1 秒後に boilingIntensity > 0.8
- 沸騰フェードアウト: isBoiling false で 1 秒後に boilingIntensity < 0.2
- 5 秒持続: usage = 0.95 を 4.9 秒 → not boiling、5.1 秒 → boiling
- isConnected = false で targetUsage = 0、isBoiling = false にリセット
- `settingsDidChange()` 後にタイマー状態が再評価される

**DutchOvenRendererTests** (3 ケース)
- 各代表状態 (idle / cooking / boiling) で `render()` が non-empty NSImage を返す
- isConnected = false で render がクラッシュしない
- 通常の使用率レンジ全域でクラッシュなし

スナップショット（PNG 一致）テストは PoC では入れない。Phase 2 でビジュアルが安定してから検討。

### 9.3 手動確認チェックリスト

- [ ] `xcodebuild build` 通る
- [ ] テスト全件 pass
- [ ] 実機起動: Disconnected pot → 接続後とろ火 → 通常時に煮込み
- [ ] `yes > /dev/null` 8 並列 + Metal ベンチで boiling 演出を視認
- [ ] ⌘, で Preferences、各 Picker 切り替えで即時反映
- [ ] アイドル時 (`top -l 1 | grep MacSlowCooker`) で CPU が ~0%（タイマー停止確認）
- [ ] アニメ `.both` モードで CPU が許容範囲（< 2%）
- [ ] HelperTool kickstart 後の再接続で animator が new sample を受けて動く

---

## 10. 動作シナリオ（受け入れ基準）

1. **起動直後**: AppDelegate → buildMainMenu → animator.setConnected(false) → グレー鍋（"--" 表示）
2. **HelperTool 接続**: onConnected → animator.setConnected(true) → 1 秒以内に最初のサンプル到着
3. **通常負荷**: usage 30% → 中火 + 湯気 1 本、補間で滑らかに上昇
4. **高負荷ワークロード**: usage 95% を 5 秒継続 → boiling 発火 → 蓋ガタガタ + 赤い湯気がフェードイン
5. **負荷解除**: usage 10% → 0.6 秒で boilingIntensity が 0 に戻り、補間で炎が落ち着く
6. **設定変更**: ⌘, → Preferences → 「炎アニメ: なし」 → 即座に反映、wiggle 停止
7. **アイドル状態**: usage = 0、wiggle off、boiling フェード完了 → タイマー停止、CPU 0%

---

## 11. 想定リスクと対策

| リスク | 対策 |
|---|---|
| 沸騰条件が PoC 中に発火しない（M3 Ultra で thermalPressure が上がりにくい） | `.combined` モードで usage 95% × 5 秒も拾う。テスト時は `yes` 並列で確実に発火させる |
| Dock アイコン更新が頻繁すぎて CPU 食う | 10 fps + 静止判定で自己停止。アニメ `.none` 時はサンプル毎の 1 回更新だけ |
| `@Observable` × `AsyncStream` 連携の実装難度 | `withObservationTracking` ループで実装。リファレンスコードを実装計画に含める |
| 設定変更時に Animator が古い `IconState` を出し続ける | `settingsDidChange()` で `ensureTimerRunning()` を呼び 1 frame 強制更新 |
| MainActor 隔離違反（Timer コールバックから状態変更） | Timer は `@MainActor` 文脈で起動、tick も MainActor 上で実行 |

---

## 12. Phase 2 以降の発展

- **おでん土鍋スタイル**: `OdenRenderer: PotRenderer` を追加、Settings に `.oden` ケース追加、Preferences に選択肢追加。コア変更なし
- **カレー鍋・中華鍋・スロークッカー（電気鍋）**: 同上
- **per-process 表示（具材プカプカ）**: IOAccelerator 系 private API 調査が前提。現状は技術検証フェーズが必要
- **ロケール検出 + 表示名切替**: `InfoPlist.strings` に `ja.lproj` 追加 + `Locale.preferredLanguages` で初期 potStyle のヒントを与える
- **スナップショットテスト**: ビジュアル安定後、`SnapshotTesting` 導入を検討
