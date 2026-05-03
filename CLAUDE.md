# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

MacSlowCooker は Mac の GPU 使用率と温度・電力を Dock アイコンとポップアップに表示する macOS デスクトップアプリ。`powermetrics` を root 権限で常駐実行する LaunchDaemon と XPC で通信する。Universal Binary (arm64 + x86_64) で Apple Silicon と Intel Mac の両方に対応。

## 開発コマンド

```bash
# プロジェクト再生成（project.yml 編集後）
xcodegen generate

# 署名ありビルド（実機動作には署名必須）
xcodebuild -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -configuration Release \
  -derivedDataPath build build \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=K38MBRNKAT

# テスト（CODE_SIGNING_ALLOWED=NO で署名スキップ可、ただし MacSlowCookerTests には INFOPLIST 設定必要）
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# 単一テストの実行
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MacSlowCookerTests/PowerMetricsParserTests/testParseValidSample
```

## デプロイ

`/Applications/MacSlowCooker.app` は root 所有になりがち。1度だけ所有権を変更すれば以降の差し替えに sudo 不要：

```bash
sudo chown -R $(whoami):staff /Applications/MacSlowCooker.app
```

その後のデプロイサイクル：

```bash
pkill -9 -x MacSlowCooker
ditto build/Build/Products/Release/MacSlowCooker.app /Applications/MacSlowCooker.app
open /Applications/MacSlowCooker.app
```

**HelperTool は launchd の管理下で動き続けるので、HelperTool 側のコードを変更したら必ず再起動が必要**：

```bash
sudo launchctl kickstart -k system/com.macslowcooker.helper
```

これをしないと、新しいバイナリを `/Applications` に置いても古いプロセスが動き続けてデバッグで混乱する。

## アーキテクチャ

```
MacSlowCooker.app（非特権、ユーザーログインセッション）
  ├── main.swift                — NSApplication.shared に AppDelegate を手動セット
  ├── AppDelegate               — XPC 接続、Dock アイコン更新、エラーアラート
  ├── GPUDataStore              — @Observable 循環バッファ（60サンプル）
  ├── Settings                  — @Observable + UserDefaults + AsyncStream<Void>
  ├── XPCClient                 — NSXPCConnection (.privileged) + 指数バックオフ再接続、2 Hz polling
  ├── HelperInstaller           — SMAppService.daemon 登録 + 古い helper の自動 re-register
  ├── DockIconAnimator          — Timer-driven state machine（補間 / wiggle / 沸騰フェード）
  ├── DutchOvenRenderer         — Core Graphics 鍋 / 炎 / 湯気描画（PotRenderer 適合）
  ├── PopupView                 — SwiftUI + Swift Charts ダッシュボード（4 chart + 4 metric）
  ├── PopupWindowController     — NSWindow（titled / closable / resizable, .floating 切替可能）
  └── PreferencesWindowController — NSWindow + SwiftUI Form

HelperTool（root LaunchDaemon、Contents/MacOS/HelperTool）
  ├── main.swift                — NSXPCListener、HelperService.shared + 内部状態は actor HelperState で隔離
  ├── PowerMetricsRunner        — /usr/bin/powermetrics 常駐、NUL 区切り plist ストリームパース
  ├── IOAcceleratorReader       — IOAccelerator → "Device Utilization %"（Activity Monitor 互換）
  ├── SMCReader                 — AppleSMC 直叩き、F0Ac/F1Ac から fan RPM
  └── TemperatureReader         — IOHIDEventSystem 経由で SoC 温度センサー読み取り
  └── SMCReader                 — AppleSMC 直叩き、fan RPM (F0Ac/F1Ac, fpe2 形式) を読み出し

Shared（両ターゲットでコンパイルされる）
  ├── GPUSample                 — Codable データモデル
  ├── XPCProtocol               — MacSlowCookerHelperProtocol
  └── PowerMetricsParser        — 静的・テスト可能な plist 解析
```

サンプル取得の流れ：
1. HelperService が起動時に PowerMetricsRunner.start() で powermetrics を spawn（Apple Silicon: `--samplers gpu_power,ane_power,thermal --show-all`、Intel: `--samplers gpu_power,thermal`）
2. NUL 区切りで届く plist を PowerMetricsParser がパース、TemperatureReader で温度を補強して JSON 化
3. XPCClient が 0.5 秒間隔（2 Hz）で `fetchLatestSample` を呼び、GPUDataStore に積んで Dock アイコンを再描画
4. 起動直後の "--" 表示を防ぐため `startSampling` で IOKit-only な primer sample（GPU% / temp / fan、power なし）を即座に格納

## macOS 26 (Tahoe) 固有の落とし穴

**powermetrics 出力フォーマット変更**: macOS 14 までの大文字キー（`GPU.gpu_active_residency`、`gpu_power_mW`、`gpu_die_temperature`）は **macOS 26 では一切存在しない**。新しい構造：
- GPU 使用率: `dict["gpu"]["idle_ratio"]` から `1 - idle_ratio` で計算
- GPU 電力: `dict["gpu"]["gpu_energy"]` (mJ) を `dict["elapsed_ns"]` で割って W 算出
- ANE 電力: `dict["processor"]["ane_power"]` (mW)、**`--show-all` フラグが必須**で出る
- GPU 温度: 露出なし（`thermal_pressure: "Nominal"` の段階値のみ）

`PowerMetricsParser` は新旧両キーを試すフォールバック設計になっている。

**`smc` sampler は macOS 26 で削除されている**: `powermetrics --help` の Available samplers は `tasks/battery/network/disk/interrupts/cpu_power/thermal/sfi/gpu_power/ane_power` のみ。`--samplers smc` を渡すと powermetrics が即クラッシュ → `PowerMetricsRunner.handleCrash()` の指数バックオフが 3 回発動して "GPU monitoring unavailable" でエラー UI が出る。fan RPM が欲しい場合は SMC を直叩きする。

**Fan RPM の取得**: `HelperTool/SMCReader.swift` が `IOServiceMatching("AppleSMC")` 経由で AppleSMC ユーザクライアントに接続、`IOConnectCallStructMethod(connection, kSMCHandleYPCEvent=2, ...)` で `FNum` (UInt8) と `F[i]Ac` (fpe2: 16-bit big-endian, 14-int + 2-frac → `raw / 4.0` で RPM) を読む。Mac Studio (Mac15,14, M3 Ultra) で 2 fan 検出。Helper は root なので IOConnect は無条件で成功する。

**温度センサー**: IOHIDEventSystem に「GPU MTR Temp Sensor」は Apple Silicon に存在しない。M3 Ultra では `PMU tdie*` / `PMU tdev*` のみ 77 個露出。Intel Mac では「GPU Proximity」「Graphics」系が見える。`TemperatureReader` は `name.contains("die") || name.contains("gpu") || name.contains("proximity") || name.contains("graphics")` で広めに拾って平均する（GPU 専用ではないため UI ラベルは Apple Silicon では「SoC 温度」、Intel では「温度」）。GPU 専用温度は SMC `Tg05` / `Tg0D` 経由でしか取れず、未実装。

**Intel powermetrics キー**: Intel Mac の powermetrics は `gpu.gpu_busy`（integer percent）または `gpu.busy_ns` + `(gpu|top).elapsed_ns` を出す。Apple Silicon の `gpu_active_residency` / `idle_ratio` キーは出ない。`PowerMetricsParser` は両系統を順に試す。

**`@main` AppDelegate の罠**: macOS 26 で `@main` を `NSApplicationDelegate` 適合クラスにつけても、`NSApp.delegate` がセットされず `applicationDidFinishLaunching` が呼ばれない。`MacSlowCooker/main.swift` で `MainActor.assumeIsolated { NSApplication.shared.delegate = AppDelegate(); NSApplication.shared.run() }` と明示的にセットしている。

**HelperTool の Info.plist 埋め込み**: `type: tool` (CLI) は通常 Info.plist を埋め込まないので codesign が `Info.plist=not bound` になり `SMAppService.daemon` が登録できない。`project.yml` の HelperTool ターゲットに：
```yaml
OTHER_LDFLAGS: "-sectcreate __TEXT __info_plist $(INFOPLIST_FILE)"
```
**さらに `-sectcreate` は変数展開しない**ので `HelperTool/Info.plist` の `CFBundleIdentifier` は `$(PRODUCT_BUNDLE_IDENTIFIER)` ではなく `com.macslowcooker.helper` をハードコード。

**HelperTool の配置**: バイナリは `Contents/MacOS/HelperTool`、plist は `Contents/Library/LaunchDaemons/com.macslowcooker.helper.plist`、plist の `BundleProgram` は `Contents/MacOS/HelperTool`。バイナリを `Contents/Library/LaunchDaemons/` に置くと `SMAppService.daemon.status` が `.notFound` になる。

**XPC 接続オプション**: LaunchDaemon の Mach service には `NSXPCConnection(machServiceName:options:)` で **`.privileged`** が必須。

**Dock アイコン表示条件**: `Info.plist` に `LSUIElement=true` があると Dock アイコン非表示。`AppDelegate` で `setActivationPolicy(.accessory)` も同様。両方排除して `.regular` で動かす（Dock アイコンクリックで `applicationShouldHandleReopen` が呼ばれる）。

**SMAuthorizedClients の要件記述子**: 緩いと（`identifier "com.macslowcooker.app" and anchor apple generic` だけだと）認証が通らない場合がある。Team OU を必ず含める：
```
identifier "com.macslowcooker.app" and anchor apple generic and certificate leaf[subject.OU] = "K38MBRNKAT"
```

## HelperTool セキュリティ

XPC 接続検証は `setCodeSigningRequirement` (macOS 13+ 公開 API) を使用。`shouldAcceptNewConnection` で connection に requirement を設定し、システムが署名検証する：

```swift
connection.setCodeSigningRequirement(
  "identifier \"com.macslowcooker.app\" and anchor apple generic and certificate leaf[subject.OU] = \"K38MBRNKAT\""
)
```

**`HelperService` はシングルトン (`HelperService.shared`)**。`shouldAcceptNewConnection` で `connection.exportedObject = HelperService.shared` を渡し、すべての接続が同じ powermetrics プロセスを共有する。接続ごとに新規インスタンスを返すと powermetrics が重複起動する。

`sampling` / `latestSampleData` は private `actor HelperState` で隔離（旧 serial queue 設計から移行済み）。XPC reply 経由のすべての mutate は `Task { await state.foo() }` でホップする。

`PowerMetricsRunner.stop()` は `isStopping = true` を立ててから `terminate()` を呼ぶ。terminationHandler が走るが `isStopping` を見て crash 扱いの再起動をスキップする。

## SourceKit の偽陽性

Shared ターゲット型（`GPUSample`, `MacSlowCookerHelperProtocol`, `GPUDataStore` 等）が他ターゲットで「not in scope」と表示されることがある。SourceKit のインデックス問題による**偽陽性**。`xcodebuild` ではビルド・テスト通る。新規 Swift ファイルを追加した場合は `xcodegen generate` 後に Xcode を再起動するとインデックスが直る。

## デバッグの定石

- アプリが起動するが何もしない → ターミナルから直接実行で stderr を見る:
  ```bash
  /Applications/MacSlowCooker.app/Contents/MacOS/MacSlowCooker
  ```
- HelperTool の状態確認:
  ```bash
  launchctl print system/com.macslowcooker.helper | head -30
  ```
- powermetrics の生 plist を捕まえる: `PowerMetricsRunner.flushSamples` で受信した chunk を `/tmp` に書き出すデバッグコードを一時的に追加（macOS 26 のキーが想定と違ったら必須）

## Intel Mac 対応

Universal Binary (`ARCHS: "arm64 x86_64"`) で両アーキテクチャに対応。`#if arch(x86_64)` でコンパイル時分岐：

- **powermetrics サンプラー**: Intel では `ane_power` サンプラーと `--show-all` を除外（ANE 非搭載）
- **PowerMetricsParser**: `gpuUsage` は `Double` 非 Optional のまま。Intel AMD GPU の `gpu_busy`（%）や `busy_ns/elapsed_ns` キーから値を計算するので、Intel でも parseable な usage を取得できる前提
- **TemperatureReader**: Intel 系センサー名 (`proximity`, `graphics`) にもマッチ
- **PopupView**: 4 chart レイアウトは Apple Silicon / Intel 共通（pot-icon-poc で統一）。ANE 電力は metric tile では露出しない

**Intel GPU (AMD Radeon) での powermetrics 出力**: 実際のキー名は macOS バージョンと GPU ベンダーで異なる。初回デプロイ時に `/tmp` への plist ダンプで確認し、`PowerMetricsParser` のキーを調整すること。

## 環境

- macOS 14 Sonoma 以降。**macOS 26 (Tahoe) で powermetrics 出力が大幅変更されている**ことに注意。
- Universal Binary: Apple Silicon (M1〜M4) + Intel Mac 対応。
- 自動署名、Team `K38MBRNKAT`。
