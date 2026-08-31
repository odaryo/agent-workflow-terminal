import Testing

@testable import Adapters
@testable import TerminalCore

/// `Adapters` ターゲットのテスト置き場。
///
/// Phase 1 では実装が無いため、モジュール構成と依存方向が壊れていないことだけを確認する。
/// 実際の CLI 出力パーサが入ったら、`Tests/AdaptersTests/Fixtures/` に保存した
/// 実出力を入力とするテストをここへ追加する (docs/coding-guidelines.md「TDD方針」)。
@Suite("Adapters ターゲットの足場")
struct AdaptersScaffoldTests {

  @Test("Adapters から TerminalCore の公開 API を参照できる")
  func canReferenceTerminalCore() {
    #expect(AgentState.unknown.worktreeCategory == .unknown)
  }
}
