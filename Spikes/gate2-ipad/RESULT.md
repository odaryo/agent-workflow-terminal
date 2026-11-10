# 段階1 実装結果

## 作成・変更したファイル

- `project.yml`: Gate2iPad、iOS 18.0、Swift 5 モード、指定 bundle ID、固定版の Citadel / SwiftTerm。
- `scripts/build-install.sh`: 環境変数検査、生成・ビルド・導入・起動の手順。実行権限あり。
- `Sources/Gate2iPadApp.swift`: 設定、公開鍵、TOFU の確認、session 一覧、端末、コピー可能な接続ログ。
- `Sources/SSHKeys.swift`: Keychain の機器鍵、SSH wire 形式の公開鍵、SHA256 指紋、TOFU の検証・保存。
- `Sources/ConnectionModel.swift`: SSH 認証、一覧取得、PTY attach、入力と window-change、background 切断・active 再接続。
- `Sources/TerminalSurface.swift`: SwiftTerm の UIViewRepresentable と delegate。端末の既定操作は変更しない。
- `README.md`: 準備・計測手順、Issue の9項目に対応する空欄の結果表、段階0と訂正コメントへのリンク。
- `RESULT.md`: この実装報告。
- リポジトリ直下 `.gitignore`: Spikes 節へ `Spikes/gate2-ipad/*.xcodeproj/` を1行追加。

## ソースを読んで確認した API

Director が指定した scratchpad 内の `src-citadel/Citadel-0.12.1/` と
`src-swiftterm/SwiftTerm-1.99.3/` を読んだ。ライブラリの実装はコピーしていない。

| 対象ソース (各ライブラリのルートからの相対パス) | 確認内容と使用箇所 |
| --- | --- |
| Citadel `Sources/Citadel/Client.swift` | `SSHClient.connect(host:port:authenticationMethod:hostKeyValidator:reconnect:...)`、`close()`。再接続は `.never` を指定し、アプリ側で同じ session を選び直す |
| Citadel `Sources/Citadel/SSHAuthenticationMethod.swift` | `import Crypto` と `ed25519(username:privateKey:)` の Curve25519 秘密鍵型 |
| Citadel `Sources/Citadel/SSHConnectionPoolSettings.swift` | `SSHReconnectMode.never` |
| Citadel `Sources/Citadel/ClientSession.swift` | `SSHHostKeyValidator.custom(_:)`、`validateHostKey(hostKey:validationCompletePromise:)`、接続時の認証完了待ち |
| Citadel `Sources/Citadel/TTY/Client/TTY.swift` | `executeCommand(_:maxResponseSize:mergeStreams:inShell:)` の ByteBuffer 戻り値と非ゼロ終了時の throw。`withPTY` の callback と終了時の channel close、PTY → ShellRequest の順序。公開 API に PTY + ExecRequest の組み合わせは見つからない |
| 同上 | `TTYOutput` の非同期列、`ExecCommandOutput.stdout/.stderr(ByteBuffer)`、`TTYStdinWriter.write(_:)` と `changeSize(cols:rows:pixelWidth:pixelHeight:)` |
| SwiftTerm `Sources/SwiftTerm/iOS/iOSTerminalView.swift` | `TerminalView(frame:font:)`、`terminalDelegate`、iOS の delegate 既定実装 (bell、リンク、OSC 52 など) |
| SwiftTerm `Sources/SwiftTerm/Apple/TerminalViewDelegate.swift` | `send(source:data:)` の ArraySlice、`sizeChanged(source:newCols:newRows:)`、必須の title / directory / scrolled / rangeChanged callback、MainActor 隔離 |
| SwiftTerm `Sources/SwiftTerm/Apple/AppleTerminalView.swift` | `feed(byteArray:)`、`terminalDimensions`、追加 clipboard delegate の既定実装。端末サイズを可変 Terminal 本体へ触れず取得できる |
| SwiftTerm `Sources/SwiftTerm/TerminalContentSnapshot.swift` | `TerminalDimensions.cols/rows` |
| 両方の `Package.swift` | 直接・推移依存、product 名、最低 OS / tools version |

Citadel の依存である Wellz26/swift-nio-ssh 0.3.4 の公開ソースも GitHub の読み取り API で確認した。

- [NIOSSHPublicKey.swift](https://github.com/Wellz26/swift-nio-ssh/blob/0.3.4/Sources/NIOSSH/Keys%20And%20Signatures/NIOSSHPublicKey.swift):
  `NIOSSHPublicKey.write(to:)` がアルゴリズム名を含む SSH wire 形式を出すこと。
  Ed25519 が長さ付きアルゴリズム名と長さ付き raw 公開鍵を格納すること。
  host key の比較・指紋はこの wire 形式に対して行う。
- [ChildChannelUserEvents.swift](https://github.com/Wellz26/swift-nio-ssh/blob/0.3.4/Sources/NIOSSH/Child%20Channels/ChildChannelUserEvents.swift):
  `PseudoTerminalRequest` の引数名、サイズの Int 型、window-change の引数。
- [SSHTerminalModes.swift](https://github.com/Wellz26/swift-nio-ssh/blob/0.3.4/Sources/NIOSSH/SSHTerminalModes.swift):
  空のモード辞書を渡せる `init(_:)`。

## 推測で書いた API と、未検証の範囲

- Citadel / SwiftTerm の呼び出しに、未確認のシグネチャを推測して使用した箇所はない。
- **ソース確認はコンパイル・実行確認ではない。** Xcode での推移依存モジュール
  (`Crypto` / `NIOCore` / `NIOSSH`) の可視性、依存解決、署名、実機のネットワーク・Keychain・UI の動作は未検証。
  `Package.resolved` と `.xcodeproj` はまだ生成していない。
- shell へのコマンド送信は spec に従ったもの。shell の初期化、tmux attach の成否、入力・IME・描画・サイズ追従、
  background の実際の切断・復帰、回線切り替え後の切断検出までの時間は、ユーザーと Director が計測する。
  ログの「attach 要求送信」を成功の実測値として扱わない。
- SwiftTerm のキー入力・IME・クリップボード・スクロール等の挙動を補正するコードは追加していない。

## 実行した確認

- `bash -n Spikes/gate2-ipad/scripts/build-install.sh`: 成功。
- `git diff --check`: 成功。新規ファイルの末尾空白も静的に確認。
- 変更範囲: `Spikes/gate2-ipad/` と `.gitignore` の Spikes 節のみ。
- ビルド、テスト、xcodegen、xcodebuild、実機操作は実行していない。
  スパイクは対象外のため lint / format も実行していない。
- commit / push / PR 作成、tmux の操作は行っていない。

## 食い違いの確認

段階0コメントの Xcode / SDK 26.5 表記は後続の訂正コメントで 27.2 に訂正済みで、今回の spec と一致する。
未解決のドキュメント・コード間の食い違いは見つからなかった。設計書の状態区分は変更していない。
