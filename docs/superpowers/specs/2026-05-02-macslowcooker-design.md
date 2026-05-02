# MacSlowCooker — 設計仕様

**日付:** 2026-05-02  
**対象:** macOS Dockアプリ（Apple Silicon専用）

---

## 概要

Apple Silicon Mac のGPU使用率をDockアイコンにリアルタイム表示し、クリックで時系列チャートと詳細メトリクスを表示するmacOSデスクトップアプリ。

---

## アーキテクチャ

### コンポーネント構成

```
MacSlowCooker.app（非特権）
  ├── AppDelegate          — Dockアイコン管理・ライフサイクル
  ├── DockIconRenderer     — Core Graphicsで縦バー描画（毎秒更新）
  ├── PopupWindowController — NSPanelの表示・非表示制御
  ├── PopupView            — SwiftUI ダッシュボードUI
  ├── GPUDataStore         — 循環バッファ・@Observable状態管理
  ├── HelperInstaller      — SMJobBless呼び出し（初回のみ）
  └── XPCClient            — HelperToolとのXPC通信クライアント

HelperTool（root権限 LaunchDaemon）
  └── main.swift           — powermetrics実行・plist解析・XPC配信

Shared/
  ├── XPCProtocol.swift    — 両ターゲット共通プロトコル
  └── GPUSample.swift      — データモデル定義
```

### データフロー

```
powermetrics (root)
  → HelperTool: plist解析
  → XPC: GPUSample 送信（1秒ごと）
  → GPUDataStore: 循環バッファ追記（60要素）
  → DockIconRenderer: Dockアイコン再描画
  → PopupView: チャート・数値更新
```

---

## データモデル

```swift
struct GPUSample: Codable {
    let timestamp: Date
    let gpuUsage: Double       // 0.0–1.0 (GPU Active Residency、常に取得可能)
    let temperature: Double?   // °C (GPU Die Temp、取得不能時nil)
    let power: Double?         // W (GPU Power、取得不能時nil)
    let aneUsage: Double?      // 0.0–1.0 (ANE Active Residency、取得不能時nil)
}
```

**XPC転送方式:** `GPUSample` を `Data` にCodableエンコードして送受信する（NSSecureCoding不使用）。

**バッファ仕様:**
- 容量: 60要素（直近60秒分）
- 間隔: 1秒
- 永続化: なし（アプリ再起動でリセット）

**powermetrics 実行コマンド:**
```bash
powermetrics --samplers gpu_power,ane_power,thermal -i 1000 --format plist
```

- HelperToolは `powermetrics` を **常駐子プロセス** として1回起動し、標準出力をストリームで読み続ける（毎秒再起動しない）
- 出力は `--format plist` によるNUL区切りストリーム。各サンプルをNUL文字で区切り、`PropertyListSerialization` で逐次パースする
- 解析対象キー: `GPU` → `GPU Active Residency` / `GPU Die Temp` / `GPU Power`、`ANE` → `ANE Active Residency`
- キーが存在しない場合は `nil` として扱い、UIでは `--` と表示する

---

## UI仕様

### Dockアイコン（縦バー型）

- サイズ: 512×512 px の `NSImage`（Core Graphics描画）
- バー色: 使用率に応じて変化
  - 0–60%: 緑 (`#4CAF50`)
  - 60–85%: 黄 (`#FFC107`)
  - 85–100%: 赤 (`#F44336`)
- バー下部に使用率テキスト（例: `68%`）を白文字で表示
- 毎秒 `NSApplication.shared.applicationIconImage` を更新
- CGBitmapContextでの描画はバックグラウンドキューで実行し、完成した `NSImage` をメインスレッドでセットする

### ポップアップウィンドウ

- ウィジェット種別: `NSPanel`（borderless, non-activating）
- サイズ: 320 × 280 pt
- 表示位置: Dockアイコン直上
- テーマ: ダークモード固定
- 閉じる条件: ウィンドウ外クリック or Dockアイコン再クリック

**レイアウト:**
```
┌──────────────────────────────┐
│ MacSlowCooker  ·  M3 Ultra          │  ← ヘッダー（デバイス名）
│                              │
│ ┌────────────┐┌────────────┐ │
│ │ GPU Usage  ││Temperature │ │  ← 折れ線チャート2本
│ │  [chart]   ││  [chart]   │ │     Swift Charts 使用
│ └────────────┘└────────────┘ │
│                              │
│  GPU 68%  Temp 47°C          │  ← 現在値4指標
│  Power 8.2W  ANE 12%         │
└──────────────────────────────┘
```

- チャート: `Chart` (Swift Charts) 折れ線 + グラデーション塗り、60秒スクロールなし固定幅
- 数値表示: 2行2列グリッド

---

## 特権ヘルパーセットアップ

> **注:** `SMJobBless` はmacOS 13で deprecated。本実装では **`SMAppService.daemon`** (macOS 13+) を使用する。

### HelperToolの配置

- Bundle ID: `com.macslowcooker.helper`
- インストール先: `/Library/PrivilegedHelperTools/com.macslowcooker.helper`
- 起動方法: launchd（`SMAppService.daemon` 登録後は自動起動）
- LaunchDaemon plist: `MacSlowCooker/Library/LaunchDaemons/com.macslowcooker.helper.plist` をapp bundleに同梱

### 初回インストールフロー

1. アプリ初回起動時に `HelperInstaller.installIfNeeded()` 呼び出し
2. `SMAppService.daemon(plistName:)` でHelperのステータス確認
3. 未登録または `CFBundleVersion` が古い場合は `register()` 実行（管理者認証ダイアログ表示）
4. 登録完了後にXPC接続開始
5. **バージョン不一致時**: `unregister()` → `register()` の順で再インストール。失敗時はDockアイコンに「!」を重ねてユーザーに通知する

### コード署名要件

| ターゲット | 要件 |
|-----------|------|
| MacSlowCooker.app | Developer ID Application で署名 |
| HelperTool | Developer ID Application で署名（同一チームID） |
| MacSlowCooker.app Info.plist | `SMPrivilegedExecutables` に `com.macslowcooker.helper` とコード署名要件を記載 |
| HelperTool Info.plist | `SMAuthorizedClients` にアプリのコード署名要件を記載 |

### XPCセキュリティ

- HelperToolの `NSXPCListenerDelegate` で接続元プロセスの **Team ID** を `auditToken` で検証する
- Team IDが不一致の場合は接続を拒否する（`shouldAcceptNewConnection` が `false` を返す）
- XPCインターフェースは「サンプリング開始/停止」のみを公開し、任意コマンド実行は受け付けない

---

## プロジェクト構成

```
MacSlowCooker/
├── MacSlowCooker.xcodeproj
├── MacSlowCooker/
│   ├── AppDelegate.swift
│   ├── DockIconRenderer.swift
│   ├── PopupWindowController.swift
│   ├── PopupView.swift
│   ├── GPUDataStore.swift
│   ├── HelperInstaller.swift   — SMAppService.daemon登録・バージョン管理
│   ├── XPCClient.swift         — 再接続ロジック含む
│   ├── Info.plist
│   └── Library/LaunchDaemons/
│       └── com.macslowcooker.helper.plist  — bundleに同梱するlaunchd plist
├── HelperTool/
│   ├── main.swift              — powermetrics常駐・NULストリームパース・XPC配信
│   └── Info.plist
├── Shared/
│   ├── XPCProtocol.swift
│   └── GPUSample.swift
└── docs/
    └── superpowers/specs/
        └── 2026-05-02-macslowcooker-design.md
```

---

## エラーハンドリング

| シナリオ | 挙動 |
|---------|------|
| powermetrics プロセス異常終了 | 5秒待機後に再起動、3回失敗でDockアイコンに「!」表示 |
| XPC接続切断（`invalidationHandler`） | 指数バックオフ（1s→2s→4s→上限30s）で再接続試行 |
| XPC中断（`interruptionHandler`） | 即座に再接続を試みる |
| HelperTool未インストール | 起動時インストールフロー開始、拒否されたらエラーバナー表示 |
| plistキー欠損 | 該当フィールドを `nil` として処理、UIでは `--` 表示 |
| HelperToolバージョン不一致 | 自動再インストール試行（§特権ヘルパーセットアップ参照） |

**degraded state:** XPC切断中もGPUDataStoreの最終値を保持し、チャートをグレーアウト表示する。

---

## ロギング

`os_log` (Unified Logging System) を使用し、サブシステム `com.macslowcooker` でカテゴリ分け:

- `app` — ライフサイクル、インストールフロー
- `xpc` — 接続/切断/再接続イベント
- `helper` — powermetricsプロセス管理、plistパース結果
- `render` — Dockアイコン描画エラー（通常は無音）

---

## 技術スタック

| 用途 | 技術 |
|------|------|
| 言語 | Swift 5.9+ |
| UI | AppKit + SwiftUI |
| 状態管理 | `@Observable` (macOS 14+) |
| チャート | Swift Charts (macOS 14+) |
| GPU データ取得 | `powermetrics` (root経由、常駐プロセス) |
| 特権管理 | `SMAppService.daemon` (ServiceManagement.framework) |
| プロセス間通信 | XPC (NSXPCConnection) |
| Dockアイコン描画 | Core Graphics (CGContext、バックグラウンドキュー) |
| ロギング | `os_log` (Unified Logging) |

---

## 対象環境

- macOS 14 Sonoma 以降（`@Observable` / `SMAppService.daemon` / Swift Charts要件）
- Apple Silicon Mac（M1/M2/M3シリーズ）
- Intel Mac非対応（powermetricsの出力形式が異なるため）
