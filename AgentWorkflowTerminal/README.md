# AgentWorkflowTerminal (Swift Package)

`agent_workflow_terminal` の core Swift Package です。Phase 1 の足場と、外部 CLI に接続する
Adapter 境界の基礎実装を収めています。macOS アプリは [`App/`](../App/) にあります。

コーディング規約は [`docs/coding-guidelines.md`](../docs/coding-guidelines.md)、
仕様は [`docs/architecture.md`](../docs/architecture.md) を参照してください。

## 命名の理由

- ディレクトリ名 / package 名 `AgentWorkflowTerminal` は、repository 名
  `agent_workflow_terminal` を Swift の型・モジュール命名規則 (UpperCamelCase) へ
  変換したものです。別のプロダクト名を作らないのは、設計書 §23.3 のとおり
  **プロダクト名が未決定**であり、ここで暫定名を増やすと後の改名コストが上がるためです。
- repository 直下に `Package.swift` を置かず、サブディレクトリに切っています。
  `Spikes/`(使い捨てコード)、`docs/`、将来の Xcode プロジェクトと並列に置き、
  「製品コードはここ」という境界を明示するためです。

## モジュール構成と依存方向

```text
TerminalCore  ←  Adapters
   ↑                ↑
TerminalCoreTests  AdaptersTests
```

依存は**一方向のみ**です。逆向き (`TerminalCore` → `Adapters`) の依存は作りません。

| ターゲット | 役割 | 依存 |
|---|---|---|
| `TerminalCore` | ドメインモデル。状態の正規化、代表状態の決定、境界 protocol の宣言。UI・外部プロセスへの依存を持たない | なし |
| `Adapters` | tmux / git CLI 等、外部世界との境界。共有境界型と parser は全 platform、ローカルプロセス実行配管は macOS のみ | `TerminalCore` |
| `TerminalCoreTests` | `TerminalCore` のテスト (Swift Testing) | `TerminalCore` |
| `AdaptersTests` | `Adapters` のテスト (Swift Testing) | `Adapters` |

### `TerminalCore` の現在の中身

| ファイル | 内容 | 出典 |
|---|---|---|
| `AgentState.swift` | 正規化状態 `working / question / permission / completed / error / idle / unknown` と、worktree 代表状態の大分類 | 設計書 §12.2 / §12.3 |
| `WorktreeRepresentativeState.swift` | worktree 代表状態を決める純粋関数 (Phase 1 の TDD リファレンス実装) | 設計書 §12.2 |
| `AgentAdapter.swift` | Agent 状態正規化の境界 protocol。**宣言のみ** | 設計書 §12.1 |
| `TerminalRenderer.swift` | Terminal 描画の境界 protocol。実装体は `App/` の `GhosttyRenderer` | 設計書 §21.5 / Gate 1 スパイク申し送り |
| `POSIXShellCommandLine.swift` | argv を POSIX shell quoting して1本の文字列にする純粋関数 | Spikes/gate1/README.md 申し送り #5 / libghostty v1.3.1 の command 契約 |

### `Adapters` の platform 境界

`ProcessRunResult` / `ProcessRunLimits` / `ProcessRunnerError` / `ProcessRunning` と
`TmuxListPanes` parser は、iOS の SSH クライアントからも使えるよう全 platform で提供します。
一方、`FoundationProcessRunner` / `ProcessExecution` / `AsyncPipeReader` / `OutputBudget` は
ローカルプロセス実行の配管であり、macOS 専用です。設計書 §20.1 のとおり実行ホストは Mac に
限定し、platform 差は同じターゲット内の条件付きコンパイルで表現しています。

`TmuxRunner` は iOS 向けにもコンパイルされますが、public initializer は端末上の既定パスから
tmux executable を探すため、iOS では `.binaryNotFound` になります。SSH 越しの実行をどう注入するかは
Gate 2 の設計対象であり、現時点では iOS から利用できる public API ではありません。

## ビルドとテスト

```shell
cd AgentWorkflowTerminal
swift build
swift test
```

### iOS 向けビルド

`TerminalCore` と、macOS 専用実装を除く `Adapters` が iOS 向けにコンパイルできることは、
次のビルドで確認します。`swift build` はテストターゲットを除く全ターゲットを対象にします。
テストターゲットは iOS 向けにビルドせず、
macOS でのみ実行します。

```shell
cd AgentWorkflowTerminal
swift build --triple arm64-apple-ios17.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
```

CI の `Build (iOS Simulator)` ジョブも同じコマンドを実行し、arm64 iOS 17 simulator triple と
iOS Simulator SDK を使って、テストターゲットを除く全ターゲットがコンパイルできることを検証します。
テストターゲット、
実機向け triple のコンパイル、simulator・実機での実行時動作は検証範囲外です。

### tmux 統合テスト

既定の `swift test` は、tmux の版数差やローカル server の状態に依存させないため、実際の tmux を
起動しません。実バイナリの解決、専用 server での detached session 作成、pane 取得、非ゼロ終了の
変換までを確認するときだけ、次のように opt-in で実行します。

```shell
cd AgentWorkflowTerminal
AWT_TMUX_INTEGRATION=1 swift test --filter TmuxRunnerIntegrationTests
```

統合テストは process ID を含む `-L awt-integration-<pid>` の専用 socket だけを使います。
`new-session -P -F '#{pid}'` で server 作成と同時に PID を取得します。tmux 3.4 では正常な
`kill-server` 後も socket ファイルが残るため、テストは `defer` で PID による停止 fallback を確保し、
専用 socket ファイルも削除します。途中でテストが失敗した場合も同じ後始末を行います。

**socket の削除は無条件ではありません。** `defer` は SIGTERM 後に最大 500ms かけて server の
消滅を確認し、確認できたときだけ socket を消します。停止できなかった場合は socket を**意図的に
残し**、標準エラーへ警告を出します。生きている server の socket を消すと `-L` から到達できない
orphan になり、手で片付けることもできなくなるためです。残った socket は後始末漏れではなく、
この判断の結果です。
2026-09-02 に tmux 3.4 で成功を確認しています。

## Lint / Format

repository ルートの設定ファイルを使います。ツール本体はこのリポジトリでは配布していません。

```shell
# フォーマット (swift-format は Swift 6 toolchain に同梱)
swift format lint --configuration .swift-format --recursive --strict \
  AgentWorkflowTerminal/Sources AgentWorkflowTerminal/Tests AgentWorkflowTerminal/Package.swift
swift format format --configuration .swift-format --recursive --in-place \
  AgentWorkflowTerminal/Sources AgentWorkflowTerminal/Tests AgentWorkflowTerminal/Package.swift

# Lint (要 `brew install swiftlint`)
swiftlint lint --config .swiftlint.yml
```

## macOS アプリ

libghostty を使う macOS アプリは、CI で core package の manifest 解決を妨げないよう
独立した SwiftPM package [`App/`](../App/) に置いています。ビルド方法と必要な外部成果物は
[`App/README.md`](../App/README.md) を参照してください。

## Swift 設定

- `swift-tools-version: 6.0`、`swiftLanguageModes: [.v6]`
  → strict concurrency (complete) が有効。
- upcoming feature `ExistentialAny` を有効化 (`any` の明示を強制)。
- deployment target は macOS 14 / iOS 17。これは足場としての暫定値であり、
  設計書での確定事項ではありません。
