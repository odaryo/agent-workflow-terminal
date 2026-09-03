# macOS アプリ

Gate 1 で検証した libghostty 統合を製品コードとして実装する独立 SwiftPM package です。
135MB の `GhosttyKit.xcframework` と、その生成に必要な Metal Toolchain を通常のソースビルドから
分離しています。CI は事前ビルド済み xcframework を Release アセットから取得して `App/` を
コンパイルしますが、xcframework 自体は CI でビルドしません。

## ビルド

CI と xcframework を自前ビルドしない開発者は、初回にリポジトリルートで次を実行します。

```shell
scripts/fetch-ghostty.sh
scripts/build-app.sh
```

生成物は `App/build/AgentWorkflowTerminal.app` です。release build は
`scripts/build-app.sh release` で作成できます。

ghostty の ref を上げる担当者だけが、`App/ghostty-ref` を更新して次を実行します。

```shell
scripts/build-ghostty.sh
scripts/wf-ghostty-publish.sh
```

`App/ghostty-ref` が利用する ghostty ref の単一の情報源です。ref の更新手順は、同ファイルを
更新し、build、publish の順に実行してから PR を作成します。`build-ghostty.sh` には zig 0.15、
Xcode、Metal Toolchain、`llvm-libtool-darwin` が必要です。
ユーザーの `~/.config/ghostty/config` は自動では読みません。設定を使う場合は
`TerminalRendererConfiguration.configurationFileURL` から明示的に指定します。
