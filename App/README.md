# macOS アプリ

Gate 1 で検証した libghostty 統合を製品コードとして実装する独立 SwiftPM package です。
135MB の `GhosttyKit.xcframework` と、その生成に必要な Metal Toolchain を GitHub Actions に
持ち込まず、`AgentWorkflowTerminal/` の build / test を単独で成立させるため分離しています。

## ビルド

初回だけリポジトリルートで次を実行します。

```shell
scripts/build-ghostty.sh
scripts/build-app.sh
```

生成物は `App/build/AgentWorkflowTerminal.app` です。release build は
`scripts/build-app.sh release` で作成できます。

`build-ghostty.sh` には zig 0.15、Xcode、Metal Toolchain、`llvm-libtool-darwin` が必要です。
ユーザーの `~/.config/ghostty/config` は自動では読みません。設定を使う場合は
`TerminalRendererConfiguration.configurationFileURL` から明示的に指定します。
