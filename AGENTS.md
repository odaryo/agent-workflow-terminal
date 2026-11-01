# AGENTS.md

Codex など Claude Code 以外のエージェント向けのプロジェクト規約。正本は以下の2つ。作業前に必ず読むこと。

- `CLAUDE.md` — リポジトリ状態、アーキテクチャ制約、ライセンス方針、ビルド/テストコマンド
- `docs/coding-guidelines.md` — コーディング規約（Swift 6 strict concurrency、protocol-oriented + 値型、TDD、§8 コメント規約）

## 最重要ルール（抜粋）

- **コード = How / テスト = What / コミットログ = Why / コードコメント = Why not。** シグネチャの言い換えコメントは書かない（`///` も同様）。詳細は guidelines §8。
- TDD: ドメインロジックと CLI 出力パースはテストファースト。テストは Swift Testing を使う。
- `Unknown` 状態を `Working` / `Idle` に丸めない。Claude Code 専用機能を作らない。tmux / git は外部 CLI プロセスとして扱う。
- 依頼されたスコープを超える変更（ついでのリファクタ・周辺整理）はしない。
- 完了条件は Director の spec に従う。Codex の sandbox では `swift build` / `swift test` が動かない（入れ子の `sandbox_apply` が拒否される）ので、ビルドとテストは試さず、`swift format lint` と `swiftlint lint --no-cache` だけを実行する。ビルドとテストは Director 側が行う。
- commit / push / PR 作成はしない。Director が変更を検証してコミットする。
- コミットは Conventional Commits、本文に Why を書く。**タイトル・本文とも日本語**（履歴が日本語で統一されており、squash マージでそのまま main のログになる）。
- ドキュメントは日本語。`docs/architecture.md` の 確定/現在の推奨/未確定/対象外 の4状態区分を勝手に変えない。

## 指示書の確認

ドキュメントと既存のコードが食い違うときはコードの書き方に従い、見つけた食い違いを最
後の返答で全て挙げること
