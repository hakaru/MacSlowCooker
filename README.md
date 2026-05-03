# MacSlowCooker

Apple Silicon Mac の GPU 使用率・SoC 温度・電力・ファン回転数を **Dock アイコン**と**フローティングウィンドウ**で可視化する macOS デスクトップアプリ。

`powermetrics` を root 権限で常駐実行する LaunchDaemon と XPC で通信し、IOAccelerator / SMC / IOHIDEventSystem も組み合わせて 1 秒間隔でメトリクスを収集する。

## 主な機能

### Dock アイコン (鍋メタファー)
- **白いダッチオーブン**型のアイコン (3D グラデーション + ドロップシャドウ)
- 鍋の色は **SoC 温度に連動** (50°C 白 → 95°C 赤オレンジ)
- **GPU 使用率に応じた炎**が鍋の下から伸縮 (色も負荷に応じて黄→赤に変化)
- 蓋から立ち昇る **〰️ 波形の湯気** がファン RPM に連動して本数・太さ・高さが変化
- 高負荷 5 秒持続または `thermalPressure ≥ Serious` で**沸騰演出**(蓋ガタガタ + 赤い湯気)
- 半透明な角丸スクエア青背景 (macOS アプリアイコン風)

### フローティングウィンドウ (Activity Monitor の "GPU の履歴" 風)
- タイトルバー付き、移動・リサイズ可能、`.floating` レベルで他アプリの上に常駐
- **4 つのチャート**: GPU / Temperature / Fan / Power (固定 Y 軸範囲)
- **4 つのメトリクスタイル**: 数値が**危険度に応じて白→黄→赤**に変化
- 半透明 NSVisualEffectView 背景

### Preferences ウィンドウ
- 鍋スタイル選択 (Phase 2 で oden / curry など追加予定)
- 炎アニメーション: Off / Interpolation / Wiggle / Both
- 沸騰トリガー: Temperature / Thermal Pressure / Combined

## アーキテクチャ

```
MacSlowCooker.app (非特権、ユーザーログインセッション)
  ├── main.swift                 — NSApplication.shared に AppDelegate 手動セット
  ├── AppDelegate                — XPC 接続、Settings 観測、メニュー構築、スリープ通知
  ├── GPUDataStore               — @Observable 循環バッファ (60 サンプル)
  ├── Settings                   — @Observable + UserDefaults + AsyncStream<Void>
  ├── XPCClient                  — NSXPCConnection (.privileged) + 指数バックオフ再接続
  ├── HelperInstaller            — SMAppService.daemon 登録・承認誘導
  ├── DockIconAnimator           — Timer-driven state machine (interpolation/wiggle/boiling fade)
  ├── DutchOvenRenderer          — Core Graphics 鍋・炎・湯気描画 (PotRenderer protocol 適合)
  ├── PopupView                  — SwiftUI ダッシュボード (4 charts + 4 metrics)
  ├── PopupWindowController      — NSWindow (titled/closable/resizable, .floating)
  └── PreferencesWindowController — NSWindow + SwiftUI Form

HelperTool (root LaunchDaemon, Contents/MacOS/HelperTool)
  ├── main.swift                 — NSXPCListener、HelperService.shared 共有
  ├── PowerMetricsRunner         — /usr/bin/powermetrics 常駐、NUL 区切り plist パース
  ├── IOAcceleratorReader        — IOAccelerator → "Device Utilization %" (GPU 使用率, ActivityMonitor 互換)
  ├── SMCReader                  — AppleSMC 直叩き、F0Ac/F1Ac から fan RPM (fpe2/flt 両対応)
  └── TemperatureReader          — IOHIDEventSystem 経由で SoC 温度

Shared (両ターゲットで共有)
  ├── GPUSample                  — Codable データモデル
  ├── XPCProtocol                — MacSlowCookerHelperProtocol
  └── PowerMetricsParser         — 静的・テスト可能な plist 解析 (legacy + macOS 26 両対応)
```

## 動作環境

- **macOS 14 Sonoma 以降** (macOS 26 Tahoe で動作確認済み)
- **Apple Silicon** (M1〜M4, Mac Studio M3 Ultra で開発・検証)
- Intel Mac は非対応
- 自動署名、Team `K38MBRNKAT`

## ビルド

```bash
# プロジェクト生成 (project.yml 編集後)
xcodegen generate

# Release ビルド (実機動作には署名必須)
xcodebuild -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -configuration Release \
  -derivedDataPath build build \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=K38MBRNKAT
```

## テスト

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

44/44 tests pass。テストカバレッジ:

- `BoilingTriggerTests` (13): 沸騰トリガーの 3 モード × 各種条件
- `DockIconAnimatorTests` (15): 補間・wiggle・沸騰フェード・タイマーライフサイクル・スリープ・dedup
- `DutchOvenRendererTests` (2): 5 状態のスモーク + 全 usage レンジでクラッシュなし
- `SettingsTests` (5): デフォルト値・永続化・フォールバック・changes AsyncStream
- 既存 (`GPUSample`, `GPUDataStore`, `PowerMetricsParser`): 9

## デプロイ

```bash
# 1 度だけ所有権変更 (以降の差し替えに sudo 不要)
sudo chown -R $(whoami):staff /Applications/MacSlowCooker.app

# デプロイサイクル
pkill -9 -x MacSlowCooker
ditto build/Build/Products/Release/MacSlowCooker.app /Applications/MacSlowCooker.app
sudo launchctl kickstart -k system/com.macslowcooker.helper   # helper 再起動 (binary 変更時)
open /Applications/MacSlowCooker.app
```

## 既知の落とし穴 (詳細は [CLAUDE.md](CLAUDE.md))

- **macOS 26 で powermetrics 出力スキーマが大幅変更** (`gpu_active_residency` → `idle_ratio`, `ane_power` の場所変更)
- **`powermetrics --samplers smc` は macOS 26 で削除済み** (fan RPM は SMC 直叩きで取得)
- **`@main` AppDelegate の罠**: macOS 26 で動作しない → `main.swift` で明示的に `delegate` セット
- **HelperTool の Info.plist 埋め込み**: `type: tool` は通常 Info.plist を埋め込まないので codesign が失敗 → `OTHER_LDFLAGS: -sectcreate __TEXT __info_plist`
- **SMAppService の `.notFound` 対応**: 正しく配置されていても `.notFound` を返すことがある → `register()` を試行

## ロードマップ

Phase 2 として以下を [GitHub Issues](https://github.com/hakaru/MacSlowCooker/issues) でトラッキング:

- 鍋スタイル追加 (おでん、カレー、中華鍋など)
- ロケール検出による表示名切り替え
- per-process 表示 (具材プカプカ)
- powermetrics 廃止 → IOReport 完全移行
- HelperService Swift Actor 化
- ファースト・サンプル遅延の改善
- その他レビューで挙がった改善項目

## ライセンス

[Apache License 2.0](LICENSE) — 商用利用 / 改変 / 再配布可。`NOTICE` の attribution 表記を維持してください。

特許条項あり: コントリビュータが提供したコードに対する特許訴訟を起こすと、その時点で当該コードに関するライセンスが失効します。

## Contributing

Issue / PR 歓迎。提出されたコードは Apache 2.0 ライセンスのもとで取り込まれます (Apache License Section 5)。
