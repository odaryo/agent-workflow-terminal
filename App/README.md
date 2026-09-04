# macOS アプリ

Gate 1 で検証した libghostty 統合を製品コードとして実装する独立 SwiftPM package です。
135MB の `GhosttyKit.xcframework` と、その生成に必要な Metal Toolchain を通常のソースビルドから
分離しています。CI は事前ビルド済み xcframework を Release アセットから取得して `App/` を
コンパイルしますが、xcframework 自体は CI でビルドしません。

## ビルド

xcframework を自前ビルドしない開発者は、初回に `gh auth login` で GitHub CLI を認証してから、
リポジトリルートで次を実行します。

```shell
scripts/fetch-ghostty.sh
scripts/build-app.sh
```

生成物は `App/build/AgentWorkflowTerminal.app` です。release build は
`scripts/build-app.sh release` で作成できます。

この Release アセットは macos-arm64 専用です。x86_64 が必要になった場合は、publish 側も
2アーキテクチャを扱えるように拡張する必要があります。

## xcframework の publish

ビルドと CI が参照する ghostty ref は `App/ghostty-ref` で管理します。初回導入と ref 更新では、
対象の変更ブランチを checkout した状態で次の順に実行します。

1. `App/ghostty-ref` を更新する（初回導入時は作成済み）
2. `scripts/build-ghostty.sh`
3. `scripts/wf-ghostty-publish.sh` で Release へ upload し、`App/ghostty-kit.sha256` を更新する
4. `App/ghostty-kit.sha256` を含めてコミットし、PR を作る

publish より先に PR を開くと、対応する Release アセットがまだ無いため `build-app` ジョブは
必ず失敗します。

`scripts/build-ghostty.sh` と `scripts/wf-ghostty-publish.sh` を使うのは、ghostty の ref を
上げる担当者だけです。`build-ghostty.sh` には zig 0.15、Xcode、Metal Toolchain、`llvm-libtool-darwin` が必要です。
ユーザーの `~/.config/ghostty/config` は自動では読みません。設定を使う場合は
`TerminalRendererConfiguration.configurationFileURL` から明示的に指定します。
