# AGENTS.md

Codex など Claude Code 以外のエージェント向けのプロジェクト規約。正本は以下の2つ。作業前に必ず読むこと。

- `CLAUDE.md` — リポジトリ状態、アーキテクチャ制約、ライセンス方針、ビルド/テストコマンド
- `docs/coding-guidelines.md` — コーディング規約（Swift 6 strict concurrency、protocol-oriented + 値型、TDD、§8 コメント規約）

## 最重要ルール（抜粋）

- **コード = How / テスト = What / コミットログ = Why / コードコメント = Why not。** シグネチャの言い換えコメントは書かない（`///` も同様）。詳細は guidelines §8。
- TDD: ドメインロジックと CLI 出力パースはテストファースト。テストは Swift Testing を使う。
- `Unknown` 状態を `Working` / `Idle` に丸めない。Claude Code 専用機能を作らない。tmux / git は外部 CLI プロセスとして扱う。
- 依頼されたスコープを超える変更（ついでのリファクタ・周辺整理）はしない。
- 完了条件: `swift build` / `swift test` / `swift format lint --strict --recursive Sources Tests`（`AgentWorkflowTerminal/` 内で実行）がすべて GREEN。
- コミットは Conventional Commits、本文に Why を書く。
- ドキュメントは日本語。`docs/architecture.md` の 確定/現在の推奨/未確定/対象外 の4状態区分を勝手に変えない。
