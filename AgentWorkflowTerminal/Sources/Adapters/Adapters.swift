/// # Adapters
///
/// 外部世界 (tmux CLI、git CLI、SSH、PTY) との境界を実装するターゲット。
///
/// Phase 1 では足場のみで、実装は入っていない。
///
/// ## このターゲットに置くもの
///
/// - `TmuxAdapter` — tmux CLI を外部プロセスとして呼び、pane / session を観測する
///   (設計書 §21.3、Spikes/gate1/README.md §8.10)。
/// - `GitReader` — git CLI の読み取り専用ラッパ (設計書 §17: Git 書き込み操作は実装しない)。
/// - `AgentAdapter` の実装体 (`ClaudeCodeAdapter` / `CodexAdapter` /
///   process detection fallback、設計書 §12.1)。
///
/// ## 依存の向き
///
/// `Adapters` → `TerminalCore` の一方向のみ。逆向きの依存を作らない。
/// CLI 出力のパーサは純粋関数として書き、実出力を fixture に保存してテストする
/// (docs/coding-guidelines.md「TDD方針」)。
enum AdaptersPlaceholder {}
