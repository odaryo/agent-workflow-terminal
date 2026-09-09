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

## 端末の設定ファイル

端末 (libghostty) の設定は `${XDG_CONFIG_HOME:-$HOME/.config}/agent-workflow-terminal/config`
から読みます。書式は ghostty の設定構文そのものです (例: `font-size = 15`)。ファイルが無ければ
何も読まず、libghostty のコンパイル既定で起動します。読み込みはプロセス起動時の 1 回だけで、
編集を反映するにはアプリを再起動します。

ghostty 本体の設定 (`~/.config/ghostty/config` などの `ghostty_config_load_default_files` が
読む経路) は**読みません**。libghostty の bundle id はコンパイル時定数 `com.mitchellh.ghostty`
なので、その経路には `~/Library/Application Support/com.mitchellh.ghostty/config` —
つまり本物の Ghostty.app 向けに書かれた設定 — が含まれ、別アプリであるこの端末へ
keybind や `scrollback-limit` が黙って効いてしまうためです (設計書 §21.6)。

## ripgrep

Viewer Drawer の検索 (設計書 §8) は ripgrep CLI を外部プロセスとして呼びます。未導入の場合は
検索だけが「ripgrep (rg) が見つかりません」と表示され、他の機能はそのまま動きます。
`brew install ripgrep` で導入してください (探す場所は `/opt/homebrew/bin/rg`、
`/usr/local/bin/rg`、`/usr/bin/rg` の順)。
