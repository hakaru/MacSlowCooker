# Changelog

すべての注目すべき変更点を記録する。フォーマットは [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠。

## [Unreleased] — 2026-05-03

### Added (Pot Icon PoC)
- **Dutch oven Dock アイコン** (3D 白鍋 + GPU 使用率連動の炎 + ファン連動の波形湯気)
  - 鍋色は SoC 温度で変化 (50°C 白 → 95°C 赤オレンジ)
  - 高負荷 5 秒持続で沸騰演出 (蓋ガタガタ + 赤い湯気)
  - 半透明青グラデーションの角丸スクエア背景
- **Activity Monitor 風のフローティングウィンドウ**
  - 4 つのチャート (GPU / Temperature / Fan / Power)
  - 4 つのメトリクスタイル (危険度カラー: 白 → 黄 → 赤)
  - リサイズ・移動可能、`.floating` レベルで他アプリの上に常駐
  - NSVisualEffectView 半透明背景
- **Preferences ウィンドウ**
  - 鍋スタイル / 炎アニメーション / 沸騰トリガー設定
  - 標準的な App / Edit / Window メニュー
- **Activity Monitor 互換の GPU 使用率**
  - `IOAccelerator` の `Device Utilization %` を直読み (powermetrics の `idle_ratio` ではない)
- **Fan RPM 取得**
  - `AppleSMC` 直叩きで `FNum` / `F0Ac` / `F1Ac` (`fpe2` + `flt ` 両形式対応)
  - macOS 26 で `powermetrics --samplers smc` が削除されたため SMC 直接アクセスに切り替え

### Architecture
- `PotRenderer` プロトコルで鍋スタイルを差し替え可能に (Phase 2 で oden / curry など追加用)
- `DockIconAnimator` Timer ベースの state machine
  - exponential lerp で滑らかな高さ補間 (時定数 0.7s)
  - sin ベースの wiggle phase で炎ゆらぎ
  - 5 秒持続の `aboveThresholdSince` 判定で沸騰トリガー
  - 静止状態で自動的に Timer 停止 → CPU 0%
  - `IconState.visualHash` で重複した Dock icon 更新を抑制 (WindowServer IPC 削減)
  - NSWorkspace スリープ通知に対応
- `Settings` を `@Observable` で実装、UserDefaults 永続化
- `Settings.changes: AsyncStream<Void>` で AppDelegate が観測
- `Clock` プロトコル + `TestClock` で時間依存ロジックを決定的にテスト

### Tests
- 44 ユニットテスト (BoilingTrigger 13 + DockIconAnimator 15 + DutchOvenRenderer 2 + Settings 5 + 既存 9)
- 全テスト pass
- スナップショット (PNG 一致) テストは PoC スコープ外

### Fixed
- `SMAppService.notFound` の誤報告に対するフォールバック (register() を直接試行)
- 旧 GPUSampleTests / GPUDataStoreTests を `thermalPressure` / `anePower` フィールド追加に追従
- `XCTestConfigurationFilePath` 環境変数で AppDelegate がテスト時にヘルパー登録をスキップ
- 鍋アイコンの炎が鍋本体の裏に隠れて見えなかった問題 (鍋の Y 位置を 36-64% に調整)

### Documentation
- 設計仕様書 (`docs/superpowers/specs/2026-05-03-pot-icon-poc-design.md`)
- 実装計画 (`docs/superpowers/plans/2026-05-03-pot-icon-poc-implementation.md`)
- macOS 26 固有の落とし穴を `CLAUDE.md` に集約

### Phase 2 Backlog (GitHub Issues)
- #1 CGLayer による静的パーツのキャッシュ
- #2 Low Power Mode 対応
- #3 SMCKeyData レイアウト保証
- #4 HelperService Swift Actor 化
- #5 powermetrics 廃止 → IOReport 完全移行
- #6 Helper version sync (binary 更新時の re-register)
- #7 macOS 26 powermetrics plist fixture テスト
- #8 nil samples をチャートで 0 表示しない
- #9 Window level / floating preference
- #10 IOAcceleratorReader 複数 service 絞り込み
- #11 First-sample latency 改善

## [Pre-PoC] — 2026-05-02

### Added (foundation work, before pot-icon-poc branch)
- 初期 Xcode プロジェクト scaffold (xcodegen)
- 縦バー型 Dock アイコン (`DockIconRenderer`, PoC で削除)
- HelperTool / XPC 通信基盤 (`MacSlowCookerHelperProtocol`)
- `PowerMetricsRunner` で powermetrics 常駐
- `TemperatureReader` で IOHIDEventSystem から SoC 温度
- `GPUDataStore` 60-element 循環バッファ
- 初期 popup UI (NSPanel)

### Renamed
- プロジェクト全体: GPUSMI → MacSlowCooker
  - bundle id, plist Label, ディレクトリ名, ヘルパーキーすべて更新

### Fixed
- macOS 26 互換性
  - `@main` の罠: AppDelegate を `main.swift` で明示セット
  - `LSUIElement` 削除で Dock アイコン表示
  - HelperTool Info.plist 埋め込み (`-sectcreate` フラグ)
  - SMAppService 登録条件 (Team OU 含む designated requirement)
  - powermetrics の新スキーマ対応 (`idle_ratio`, `gpu_energy`)
- IOHID GPU temperature クラッシュを `readGPUTemperature()` 一時無効化で回避
