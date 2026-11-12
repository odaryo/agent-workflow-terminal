# iPad アプリ

`AgentWorkflowTerminalMobile` は iOS 17.0 以降の iPad 向け SwiftUI アプリです。
この段では「接続先は未設定です」と表示する画面だけを持ち、SwiftTerm・NIOSSH・NIOPosix の
import を通じて依存をビルドできることを確認します。

- `project.yml`: XcodeGen の定義。SwiftTerm 1.99.3、swift-nio-ssh 0.15.1、swift-nio 2.105.0 を固定。
- `Sources/`: アプリのソース。
- `AgentWorkflowTerminalMobile.xcodeproj` と `DerivedData/`: 生成物。Git では追跡しません。

## 前提

- Swift 6.2 以降を含む Xcode。CI の iPad アプリの段では Xcode 26.3 を使います。
  SwiftTerm 1.99.3 の tools version が 6.2 のため、Xcode 16.4 では依存を解決できません。
- XcodeGen 2.46.0。PATH に置くか、以下の取得スクリプトで取得して `XCODEGEN` に指定します。
- 実機へのインストールには Apple ID と無料の Personal Team、USB 接続した iPad が必要です。
  Simulator 向けビルドには署名は不要です。

以下のコマンド例はリポジトリ直下で実行します。ビルドとインストールのスクリプト自体は、
どのディレクトリから呼んでもリポジトリ直下を基準に動きます。

## ローカルでビルドする

```sh
# 必要な場合、使用する Xcode を選択する
export DEVELOPER_DIR=/Applications/Xcode_26.3.app

# PATH に XcodeGen が無ければ、固定した sha256 を検証して取得する
export XCODEGEN="$(scripts/fetch-xcodegen.sh "$TMPDIR/awt-xcodegen")"
scripts/build-ios.sh
```

PATH に `xcodegen` がある場合は、`XCODEGEN` を設定せず `scripts/build-ios.sh` を実行できます。
スクリプトはプロジェクトを生成し、Debug の iOS Simulator 向けビルドを行います。
SwiftTerm の build tool plugin があるため、非対話で動かすビルドでは
`-skipPackagePluginValidation` を指定しています。

## 無料の Personal Team 署名で実機へ入れる

1. Xcode の **Settings > Accounts** に Apple ID を登録し、Personal Team を利用できるようにします。
2. iPad を USB で Mac へ接続し、iPad で Mac を信頼します。
   iPad の **設定 > プライバシーとセキュリティ > デベロッパモード (Developer Mode)** を有効にし、
   案内に従って再起動・確認します。
3. プロジェクトを生成します。`XCODEGEN` を設定した場合は `"$XCODEGEN"` を使います。

   ```sh
   xcodegen generate --spec iOS/project.yml
   # 取得スクリプトを使った場合:
   # "$XCODEGEN" generate --spec iOS/project.yml
   ```

4. 生成したプロジェクトを Xcode で開き、ターゲットの **Signing & Capabilities > Team** で
   Personal Team を選びます。**Build Settings > DEVELOPMENT_TEAM** の値が Team ID です。
   この値は次の環境変数に使います。`project.yml` には書かず、スクリプトのビルド時に渡します。
5. 次のコマンドで接続した iPad の ID を調べます。2種類の ID はそれぞれの出力から取得します。

   ```sh
   xcodebuild -project iOS/AgentWorkflowTerminalMobile.xcodeproj \
     -scheme AgentWorkflowTerminalMobile -showdestinations
   xcrun devicectl list devices
   ```

   `-showdestinations` の実機 iPad の `id` を `AWT_IPAD_XCODEBUILD_ID` に、
   `devicectl list devices` の同じ iPad の `Identifier` を `AWT_IPAD_DEVICECTL_ID` に使います。
6. 環境変数を設定してインストールします。

   ```sh
   export AWT_DEVELOPMENT_TEAM='Personal Team の Team ID'
   export AWT_IPAD_XCODEBUILD_ID='xcodebuild の id'
   export AWT_IPAD_DEVICECTL_ID='devicectl の Identifier'
   scripts/install-ios.sh
   ```

   スクリプトはプロジェクトを再生成し、Personal Team の自動署名で実機向け Debug ビルドを行い、
   インストールして起動します。プロファイル更新とデバイス登録を許可するオプションも指定します。
   3つの環境変数のどれかが空なら、生成やビルドを行わず調べ方を表示して終了します。
7. 初回は iPad の **設定 > 一般 > VPN とデバイス管理** で開発元を信頼します。
   信頼する前の起動が失敗した場合は、信頼した後に iPad の AWT アイコンから開いてください。

無料署名のプロファイルは7日で切れるため、期限が切れたら `scripts/install-ios.sh` で入れ直します。
Bundle ID は **`dev.odaryo.agentworkflowterminal.ios`** のまま使ってください。
無料の Personal Team には App ID 作成数の週の上限があるため、変更するたびに別の App ID を消費します。

## CI

既存の `checks` ジョブ内の `Build (iPad app)` 段で XcodeGen を sha256 検証付きで取得し、
Simulator 向けにビルドします。この段だけ `DEVELOPER_DIR=/Applications/Xcode_26.3.app` を設定し、
ほかの段は runner の既定の Xcode 16.4 を使います。ビルド時間は PR の CI で確認します。
