# AgentWorkflowTerminal (Swift Package)

`agent_workflow_terminal` の Swift Package です。Phase 1 (足場づくり) の成果物であり、
**機能実装は入っていません**。

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
| `Adapters` | tmux / git CLI 等、外部世界との境界の実装。Phase 1 ではプレースホルダのみ | `TerminalCore` |
| `TerminalCoreTests` | `TerminalCore` のテスト (Swift Testing) | `TerminalCore` |
| `AdaptersTests` | `Adapters` のテスト (Swift Testing) | `Adapters` |

### `TerminalCore` の現在の中身

| ファイル | 内容 | 出典 |
|---|---|---|
| `AgentState.swift` | 正規化状態 `working / question / permission / completed / error / idle / unknown` と、worktree 代表状態の大分類 | 設計書 §12.2 / §12.3 |
| `WorktreeRepresentativeState.swift` | worktree 代表状態を決める純粋関数 (Phase 1 の TDD リファレンス実装) | 設計書 §12.2 |
| `AgentAdapter.swift` | Agent 状態正規化の境界 protocol。**宣言のみ** | 設計書 §12.1 |
| `TerminalRenderer.swift` | Terminal 描画の境界 protocol。**宣言のみ** | 設計書 §21.5 / Gate 1 スパイク申し送り |

## ビルドとテスト

```shell
cd AgentWorkflowTerminal
swift build
swift test
```

### tmux 統合テスト

既定の `swift test` は、tmux の版数差やローカル server の状態に依存させないため、実際の tmux を
起動しません。実バイナリの解決、専用 server での detached session 作成、pane 取得、非ゼロ終了の
変換までを確認するときだけ、次のように opt-in で実行します。

```shell
cd AgentWorkflowTerminal
AWT_TMUX_INTEGRATION=1 swift test --filter TmuxRunnerIntegrationTests
```

統合テストは process ID を含む `-L awt-integration-<pid>` の専用 socket だけを使います。
tmux 3.4 では正常な `kill-server` 後も socket ファイルが残るため、テストは `defer` で server を
停止する fallback を確保し、`kill-server` の完了後に専用 socket ファイルも削除します。途中で
テストが失敗した場合も同じ後始末を行います。
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

## アプリ本体 (SwiftUI app / Xcode プロジェクト) について

**Phase 1 では作りません。** 理由:

- `TerminalRenderer` に libghostty を使う macOS アプリの参照実装は
  `Spikes/gate1/`(Gate 1 スパイク) に既に存在し、SwiftUI + libghostty + PTY + tmux が
  動くことは実測済みです。同じものをもう1つ作る価値がありません。
- 設計書 §24 の Gate 2 以降 (iOS/SSH、Agent Adapter 等) が未実施であり、
  アプリの形を今固定すると、未確定事項を暗黙に確定させてしまいます。
- Phase 1 の目的は規約と足場の確定であり、アプリのシェルはその対象外です。

アプリターゲットは、Gate 2 以降の結果を踏まえて別フェーズで追加します。
その際は `Spikes/gate1/` を参照実装として扱い、コードをそのままコピーするのではなく
規約 (docs/coding-guidelines.md) に沿って書き直します。

## Swift 設定

- `swift-tools-version: 6.0`、`swiftLanguageModes: [.v6]`
  → strict concurrency (complete) が有効。
- upcoming feature `ExistentialAny` を有効化 (`any` の明示を強制)。
- deployment target は macOS 14 / iOS 17。これは足場としての暫定値であり、
  設計書での確定事項ではありません。
