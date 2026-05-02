# MacSlowCooker

Apple Silicon Mac の GPU 使用率と SoC 温度・電力を Dock アイコンとポップアップに表示する macOS デスクトップアプリ。

`powermetrics` を root 権限で常駐実行する LaunchDaemon と XPC で通信し、1 秒間隔でメトリクスを収集する。

## 動作環境

- macOS 14 Sonoma 以降（macOS 26 Tahoe 対応済み）
- Apple Silicon (M1〜M4)。Intel 非対応
- Xcode 16 以上、Swift 5.9

## 構成

```
MacSlowCooker.app（非特権、ユーザーログインセッション）
  ├── AppDelegate              — XPC 接続、Dock アイコン更新、エラーアラート
  ├── GPUDataStore             — @Observable 循環バッファ（60 サンプル）
  ├── XPCClient                — NSXPCConnection (.privileged) + 指数バックオフ再接続
  ├── HelperInstaller          — SMAppService.daemon の登録・承認誘導
  ├── DockIconRenderer         — Core Graphics 縦バー描画
  ├── PopupView                — SwiftUI + Swift Charts ダッシュボード
  └── PopupWindowController    — NSPanel（Dock アイコン直上にフロート）

HelperTool（root LaunchDaemon）
  ├── PowerMetricsRunner       — powermetrics 常駐、NUL 区切り plist ストリームパース
  └── TemperatureReader        — IOHIDEventSystem 経由で SoC 温度センサー読み取り

Shared
  ├── GPUSample                — Codable データモデル
  ├── XPCProtocol              — MacSlowCookerHelperProtocol
  └── PowerMetricsParser       — 静的・テスト可能な plist 解析
```

## ビルド

```bash
# プロジェクト生成（project.yml 編集後）
xcodegen generate

# 署名ありビルド（実機動作には署名必須）
xcodebuild -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -configuration Release \
  -derivedDataPath build build \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=K38MBRNKAT
```

## テスト

```bash
xcodebuild test -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## デプロイ

`/Applications/MacSlowCooker.app` は root 所有になりがち。1 度だけ所有権を変更すれば以降の差し替えに sudo 不要：

```bash
sudo chown -R $(whoami):staff /Applications/MacSlowCooker.app
```

差し替えサイクル：

```bash
pkill -9 -x MacSlowCooker
ditto build/Build/Products/Release/MacSlowCooker.app /Applications/MacSlowCooker.app
open /Applications/MacSlowCooker.app
```

HelperTool は launchd 管理下で動き続けるため、HelperTool 側を変更したら再起動が必要：

```bash
sudo launchctl kickstart -k system/com.macslowcooker.helper
```

## ライセンス

未定。

## 詳細

開発者向けの落とし穴（macOS 26 の powermetrics 出力変更、SMAppService 登録条件、`@main` の罠など）は [CLAUDE.md](CLAUDE.md) を参照。
