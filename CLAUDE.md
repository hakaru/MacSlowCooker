# GPUSMI — プロジェクトガイド

Apple Silicon MacのGPU使用率をDockアイコンにリアルタイム表示するmacOSデスクトップアプリ。

---

## アーキテクチャ概要

```
GPUSMI.app（非特権）
  ├── AppDelegate        — @main、全体ワイヤリング
  ├── GPUDataStore       — @Observable 循環バッファ（60要素）
  ├── XPCClient          — XPC接続・指数バックオフ再接続
  ├── HelperInstaller    — SMAppService.daemon 登録
  ├── DockIconRenderer   — Core Graphics 縦バー描画（BGキュー）
  ├── PopupView          — SwiftUI + Swift Charts ダッシュボード
  └── PopupWindowController — NSPanel（Dockアイコン直上）

HelperTool（root権限 LaunchDaemon）
  ├── main.swift         — NSXPCListener・HelperService
  └── PowerMetricsRunner — powermetrics常駐プロセス・NULストリームパース

Shared（両ターゲット共通）
  ├── GPUSample.swift       — Codableデータモデル
  ├── XPCProtocol.swift     — XPCプロトコル定義
  └── PowerMetricsParser.swift — plist解析（静的・テスト可能）
```

## ビルド方法

```bash
# コード署名なしでビルド
xcodebuild build -project GPUSMI.xcodeproj -scheme GPUSMI CODE_SIGNING_ALLOWED=NO

# テスト実行
xcodebuild test -project GPUSMI.xcodeproj -scheme GPUSMI -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

実際に動かす場合はXcodeでDevelopment Teamを設定して署名が必要。初回起動時にHelperToolインストールのため管理者パスワードを求めるダイアログが表示される。

## XcodeGenによるプロジェクト再生成

`project.yml` を編集したら：

```bash
xcodegen generate
```

## 重要な設計上の決定

### SourceKitの偽陽性エラーについて
Sharedターゲットの型（`GPUSample`、`GPUSMIHelperProtocol`など）がHelperToolやGPUSMIターゲットのファイルで「not in scope」と表示されることがある。これはSourceKitのインデックス問題による**偽陽性**。`xcodebuild`では正常にビルド・テストが通る。

### powermetricsのキー名
Task 1で実機確認済み:
- GPU使用率: `gpu_active_residency`（0.0〜1.0）
- GPU電力: `gpu_power_mW`（mW単位 → W変換して格納）
- 温度: `GPU Die Temp` または `gpu_die_temperature`
- ANE使用率: `ane_active_residency`（0.0〜1.0）

### SMAppService.daemonについて
`SMJobBless`はmacOS 13でdeprecated。本プロジェクトは`SMAppService.daemon`（macOS 13+）を使用。`requiresApproval`ステータスの場合は`SMAppService.openSystemSettingsLoginItems()`でSystem Settings（ログイン項目）を開く。

### XPC接続戦略
- **切断（invalidation）**: 指数バックオフ（1s→2s→4s→上限30s）で再接続
- **中断（interruption）**: 即座に再接続（バックオフなし）

### powermetricsクラッシュ対応
クラッシュ検出 → 5秒待機 → 再起動。3回失敗したら`onError`を呼んで諦める。

### Dockアイコン色
仕様書の指定色（sRGB）:
- 緑: `#4CAF50`（使用率 < 60%）
- 黄: `#FFC107`（60% 〜 85%）
- 赤: `#F44336`（85% 以上）

### デバイス名表示
`sysctlbyname("hw.model")` で実デバイス名（例: `Mac Pro` など）を動的取得。

## テスト構成

| テストクラス | 件数 | 内容 |
|---|---|---|
| `GPUSampleTests` | 2 | Codable encode/decode |
| `PowerMetricsParserTests` | 3 | plist解析・nilフィールド |
| `GPUDataStoreTests` | 4 | 循環バッファ・接続状態 |
| `DockIconRendererTests` | 3 | 画像サイズ検証 |

## 対象環境

- macOS 14 Sonoma 以降（`@Observable` / `SMAppService.daemon` / Swift Charts要件）
- Apple Silicon Mac（M1/M2/M3/M4シリーズ）
- Intel Mac非対応（powermetricsの出力形式が異なるため）
